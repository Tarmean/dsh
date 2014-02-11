{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE LambdaCase       #-}

-- | Common tools for rewrites
module Database.DSH.CL.Opt.Aux 
    ( applyExpr
    , applyT
      -- * Monad rewrites with additional state
    , TuplifyM
      -- * Converting predicate expressions into join predicates
    , splitJoinPredT
    -- * Pushing guards towards the front of a qualifier list
    , isSimplePred
    , isLocalComplexPred
    , pushSimpleFilters
    , pushEquiFilters
    , pushSemiFilters
    , pushAntiFilters
    , pushComplexFilters
      -- * Free and bound variables
    , freeVars
    , compBoundVars
      -- * Substituion
    , substR
    , tuplifyR
      -- * Combining generators and guards
    , insertGuard
      -- * Generic iterator to merge guards into generators
    , Comp(..)
    , mergeGuardsIterR
      -- * NL spine traversal
    , onetdSpineT
      -- * Debugging
    , debug
    , debugPretty
    , debugMsg
    , debugOpt
    , debugPipeR
    , debugTrace
    , debugShow
    ) where
    
import           Control.Arrow
import qualified Data.Foldable as F
import           Data.List
import           Debug.Trace
import qualified Data.Set as S
import           Data.Either

import           Language.KURE                 

import           Database.DSH.Impossible
import           Database.DSH.Common.Pretty
import           Database.DSH.CL.Lang
import           Database.DSH.CL.Kure
import           Database.DSH.CL.Monad

-- | A version of the CompM monad in which the state contains an additional
-- rewrite. Use case: Returning a tuplify rewrite from a traversal over the
-- qualifier list so that it can be applied to the head expression.
type TuplifyM = CompSM (RewriteC CL)

-- | Run a translate on an expression without context
applyExpr :: TranslateC CL b -> Expr -> Either String b
applyExpr f e = runCompM $ apply f initialCtx (inject e)

-- | Run a translate on any value which can be injected into CL
applyT :: Injection a CL => TranslateC CL b -> a -> Either String b
applyT t e = runCompM $ apply t initialCtx (inject e)
          

--------------------------------------------------------------------------------
-- Rewrite general expressions into equi-join predicates

toJoinExpr :: Ident -> TranslateC Expr JoinExpr
toJoinExpr n = do
    e <- idR
    
    let prim1 :: (Prim1 a) -> TranslateC Expr UnOp
        prim1 (Prim1 Fst _) = return FstJ
        prim1 (Prim1 Snd _) = return SndJ
        prim1 (Prim1 Not _) = return NotJ
        prim1 _             = fail "toJoinExpr: primitive can't be translated to join primitive"
        
    case e of
        AppE1 t p _   -> do
            p' <- prim1 p
            appe1T (toJoinExpr n) (\_ _ e1 -> UnOpJ t p' e1)
        BinOp t _ _ _ -> do
            binopT (toJoinExpr n) (toJoinExpr n) (\_ o e1 e2 -> BinOpJ t o e1 e2)
        Lit t v       -> do
            return $ ConstJ t v
        Var t x       -> do
            guardMsg (n == x) "toJoinExpr: wrong name"
            return $ InputJ t
        _             -> do
            fail "toJoinExpr: can't translate to join expression"
            
-- | Try to transform an expression into an equijoin predicate. This will fail
-- if either the expression does not have the correct shape (equality with
-- simple projection expressions on both sides) or if one side of the predicate
-- has free variables which are not the variables of the qualifiers given to the
-- function.
splitJoinPredT :: Ident -> Ident -> TranslateC Expr (JoinExpr, JoinExpr)
splitJoinPredT x y = do
    BinOp _ Eq e1 e2 <- idR

    let fv1 = freeVars e1
        fv2 = freeVars e2
        
    if [x] == fv1 && [y] == fv2
        then binopT (toJoinExpr x) (toJoinExpr y) (\_ _ e1' e2' -> (e1', e2'))
        else if [y] == fv1 && [x] == fv2
             then binopT (toJoinExpr y) (toJoinExpr x) (\_ _ e1' e2' -> (e2', e1'))
             else fail "splitJoinPredT: not an equi-join predicate"

---------------------------------------------------------------------------------
-- Pushing filters towards the front of a qualifier list

-- | Push guards as far as possible towards the front of the qualifier
-- list. Predicate 'mayPush' decides wether a guard might be pushed at all. The
-- rewrite fails if no guard can be pushed.
pushFilters :: ([Ident] -> Expr -> Bool) -> RewriteC Expr
pushFilters mayPush = do
    Comp _ _ _ <- idR
    compR idR (pushFiltersQuals mayPush)

pushFiltersQuals :: ([Ident] -> Expr -> Bool) -> RewriteC (NL Qual)
pushFiltersQuals mayPush = do
    (reverseNL . initFlags mayPush)
      ^>> checkSuccess
      -- FIXME using innermostR here is really inefficient!
      >>> innermostR tryPush 
      >>^ (reverseNL . fmap snd)
      
-- | Fail if no guard can be pushed
checkSuccess :: RewriteC (NL (Bool, Qual))
checkSuccess = do
    qs <- idR
    if (any fst $ toList qs)
        then return qs
        else fail "no guards can be pushed"
    
-- Mark all guards which may be pushed based on a general predicate
-- `mayPush`. To this predicate, we pass the guard expression as well as the
-- list of identifiers which are in scope for the current guard.
initFlags :: ([Ident] -> Expr -> Bool) -> NL Qual -> NL (Bool, Qual)
initFlags mayPush qs = 
    case fromList flaggedQuals of
        Just qs' -> qs'
        Nothing  -> $impossible
  where
    flaggedQuals = reverse
                   $ snd
                   $ foldl' (flagQualifiers mayPush) (Nothing, []) 
                   $ zip localScopes (toList qs)

    localScopes = map compBoundVars $ inits $ toList qs

    
-- | For each guard, decide wether it may be pushed or not and mark it
-- accordingly. If a guard is located directly next to a generator
-- binding a variable which occurs free in the guard, it is marked
-- unpushable without looking at it further.
flagQualifiers 
  :: ([Ident] -> Expr -> Bool)
  -> (Maybe Ident, [(Bool, Qual)]) 
  -> ([Ident], Qual) 
  -> (Maybe Ident, [(Bool, Qual)])
flagQualifiers mayPush (mPrevBind, flaggedQuals) (localScope, qual) =
    case (mPrevBind, qual) of
        -- No generator left of the guard. Only look at the guard
        -- itself.
        (Nothing, GuardQ p) -> 
            (Nothing, (mayPush localScope p, qual) : flaggedQuals)

        -- Guard is located left of a generator which binds one guard
        -- expression variable. It must not be pushed.
        (Just x, GuardQ p) | x `elem` freeVars p -> 
            (Nothing, (False, qual) : flaggedQuals)

        -- There is a generator left of the guard, but the bound
        -- variable does not occur in the guard expression.
        (Just _, GuardQ p) | otherwise           -> 
            (Nothing, (mayPush localScope p, qual) : flaggedQuals)
            
        -- Generators are never pushed. Just hand the bound variable to
        -- the next qualifier.
        (_, BindQ x _) -> 
            (Just x, (False, qual) : flaggedQuals)
                       
tryPush :: RewriteC (NL (Bool, Qual))
tryPush = do
    qualifiers <- idR 
    case qualifiers of
        q1@(True, GuardQ p) :* q2@(_, BindQ x _) :* qs ->
            if x `elem` freeVars p
            -- We can't push through the generator because it binds a
            -- variable we depend upon
            then return $ (False, GuardQ p) :* q2 :* qs
               
            -- We can push
            else return $ q2 :* q1 :* qs
            
        q1@(True, GuardQ _) :* q2@(_, GuardQ _) :* qs  ->
            return $ q2 :* q1 :* qs

        (True, GuardQ p) :* (S q2@(_, BindQ x _))      ->
            if x `elem` freeVars p
            then return $ (False, GuardQ p) :* (S q2)
            else return $ q2 :* (S (False, GuardQ p))

        (True, GuardQ p) :* (S q2@(_, GuardQ _))       ->
            return $ q2 :* (S (False, GuardQ p))

        (True, BindQ _ _) :* _                         ->
            error "generators can't be pushed"

        (False, _) :* _                                ->
            fail "can't push: node marked as unpushable"

        S (True, q)                                    ->
            return $ S (False, q)

        S (False, _)                                   ->
            fail "can't push: already at front"


isEquiJoinPred :: [Ident] -> Expr -> Bool
isEquiJoinPred locallyBoundVars (BinOp _ Eq e1 e2) = 
    isFlatExpr e1 
    && isFlatExpr e2
    && length fv1 == 1
    && length fv2 == 1
    && fv1 /= fv2
    
    -- For an equi join predicate which we would like to push, only variables
    -- bound by local generators might occur. This restriction should avoid the
    -- case that a predicate which correlates with an outer comprehension blocks
    -- a local equijoin predicate from being pushed next to its generators.
    && (fv1 ++ fv2) `subset` locallyBoundVars

  where fv1 = freeVars e1
        fv2 = freeVars e2
        
        subset :: Eq a => [a] -> [a] -> Bool
        subset as bs = all (\a -> any (== a) bs) as
isEquiJoinPred _ _                  = False

-- | Does the predicate look like an existential quantifier and is eligible for
-- pushing? Note: In addition to the variables that are bound by the current
-- qualifier list, we need to pass the variable bound by the existential
-- comprehension to isEquiJoinPred, because it might (and should) occur in the
-- predicate.
isSemiJoinPred :: [Ident] -> Expr -> Bool
isSemiJoinPred vs (AppE1 _ (Prim1 Or _) 
                           (Comp _ p 
                                   (S (BindQ x _)))) = isEquiJoinPred (x : vs) p
isSemiJoinPred _  _                                  = False

isAntiJoinPred :: [Ident] -> Expr -> Bool
isAntiJoinPred vs (AppE1 _ (Prim1 And _) 
                           (Comp _ p
                                   (S (BindQ x _)))) = isEquiJoinPred (x : vs) p
isAntiJoinPred _  _                                  = False

isFlatExpr :: Expr -> Bool
isFlatExpr expr =
    case expr of
        AppE1 _ (Prim1 Fst _) e -> isFlatExpr e
        AppE1 _ (Prim1 Snd _) e -> isFlatExpr e
        AppE1 _ (Prim1 Not _) e -> isFlatExpr e
        BinOp _ _ e1 e2         -> isFlatExpr e1 && isFlatExpr e2
        Var _ _                 -> True
        Lit _ _                 -> True
        _                       -> False
        

-- A simple predicate is a predicate that we may push early into
-- generators. Requirements are
-- - It is local, i.e. refers only to vars bound in the local comprehension
-- - It only refers to one generator (i.e. a local one)
-- - It is structurally simple, i.e. flat. comparison
isSimplePred :: [Ident] -> Expr -> Bool
isSimplePred localScope e = 
  isLocalPred localScope e
  &&
  length (freeVars e) == 1
  &&
  isFlatExpr e

isLocalComplexPred :: [Ident] -> Expr -> Bool
isLocalComplexPred localScope e =
    isLocalPred localScope e
    && length (freeVars e) == 1

-- | Are all free variables in the predicate bound in the local comprehension?
isLocalPred :: [Ident] -> Expr -> Bool
isLocalPred localScope e = all (\v -> v `elem` localScope) (freeVars e)

pushEquiFilters :: RewriteC Expr
pushEquiFilters = pushFilters isEquiJoinPred
       
pushSemiFilters :: RewriteC Expr
pushSemiFilters = pushFilters isSemiJoinPred

pushAntiFilters :: RewriteC Expr
pushAntiFilters = pushFilters isAntiJoinPred

pushAllFilters :: RewriteC Expr
pushAllFilters = pushFilters (\_ _ -> True)

-- | Push only predicates which are local (do not refer to variables
-- bound in enclosing comprehensions), refer to only one generator and
-- are structurally simple.
pushSimpleFilters :: RewriteC Expr
pushSimpleFilters = pushFilters isSimplePred
                  
-- | Push only predicates which are local (do not refer to variables
-- bound in enclosing comprehensions) and refer to only one
-- generator. The filter expression itself, however, may be
-- complicated.
pushComplexFilters :: RewriteC Expr
pushComplexFilters = pushFilters isLocalComplexPred 

--------------------------------------------------------------------------------
-- Computation of free variables

freeVarsT :: TranslateC CL [Ident]
freeVarsT = fmap nub $ crushbuT $ promoteT $ do (ctx, Var _ v) <- exposeT
                                                guardM (v `freeIn` ctx)
                                                return [v]
                                                
-- | Compute free variables of the given expression
freeVars :: Expr -> [Ident]
freeVars = either error id . applyExpr freeVarsT

-- | Compute all identifiers bound by a qualifier list
compBoundVars :: F.Foldable f => f Qual -> [Ident]
compBoundVars qs = F.foldr aux [] qs
  where 
    aux :: Qual -> [Ident] -> [Ident]
    aux (BindQ n _) ns = n : ns
    aux (GuardQ _) ns  = ns

--------------------------------------------------------------------------------
-- Substitution

alphaLamR :: RewriteC Expr
alphaLamR = do (ctx, Lam lamTy v _) <- exposeT
               v' <- constT $ freshName (inScopeVars ctx)
               let varTy = domainT lamTy
               lamT (extractR $ tryR $ substR v (Var varTy v')) (\_ _ -> Lam lamTy v')
              
nonBinder :: Expr -> Bool
nonBinder expr =
    case expr of
        Lam _ _ _  -> False
        Var _ _    -> False
        Comp _ _ _ -> False
        _          -> True
                                                
substR :: Ident -> Expr -> RewriteC CL
substR v s = readerT $ \case
    -- Occurence of the variable to be replaced
    ExprCL (Var _ n) | n == v                          -> return $ inject s

    -- Some other variable
    ExprCL (Var _ _)                                   -> idR

    -- A lambda which does not shadow v and in which v occurs free. If the
    -- lambda variable occurs free in the substitute, we rename the lambda
    -- variable to avoid name capturing.
    ExprCL (Lam _ n e) | n /= v && v `elem` freeVars e -> 
        if n `elem` freeVars s
        then promoteR alphaLamR >>> substR v s
        else promoteR $ lamR (extractR $ substR v s)

    -- A lambda which shadows v -> don't descend
    ExprCL (Lam _ _ _)                                 -> idR
    
    -- If some generator shadows v, we must not substitute in the comprehension
    -- head. However, substitute in the qualifier list. The traversal on
    -- qualifiers takes care of shadowing generators.
    ExprCL (Comp _ _ qs) | v `elem` compBoundVars qs   -> promoteR $ compR idR (extractR $ substR v s)
    ExprCL (Comp _ _ _)                                -> promoteR $ compR (extractR $ substR v s) (extractR $ substR v s)
    
    ExprCL (Lit _ _)                                   -> idR
    ExprCL (Table _ _ _ _)                             -> idR
    ExprCL _                                           -> anyR $ substR v s
    
    -- Don't substitute past shadowingt generators
    QualsCL ((BindQ n _) :* _) | n == v                -> promoteR $ qualsR (extractR $ substR v s) idR
    QualsCL (_ :* _)                                   -> promoteR $ qualsR (extractR $ substR v s) (extractR $ substR v s)
    QualsCL (S _)                                      -> promoteR $ qualsemptyR (extractR $ substR v s)
    QualCL _                                           -> anyR $ substR v s
    

--------------------------------------------------------------------------------
-- Tuplifying variables

-- | Turn all occurences of two identifiers into accesses to one tuple variable.
-- tuplifyR z c y e = e[fst z/x][snd z/y]
tuplifyR :: Ident -> (Ident, Type) -> (Ident, Type) -> RewriteC CL
tuplifyR v (v1, t1) (v2, t2) = substR v1 v1Rep >+> substR v2 v2Rep
  where 
    (v1Rep, v2Rep) = tupleVars v t1 t2

tupleVars :: Ident -> Type -> Type -> (Expr, Expr)
tupleVars n t1 t2 = (v1Rep, v2Rep)
  where v     = Var pt n
        pt    = pairT t1 t2
        v1Rep = AppE1 t1 (Prim1 Fst (pt .-> t1)) v
        v2Rep = AppE1 t2 (Prim1 Snd (pt .-> t2)) v

--------------------------------------------------------------------------------
-- Helpers for combining generators with guards in a comprehensions'
-- qualifier list

-- | Insert a guard in a qualifier list at the first possible
-- position.
insertGuard :: Expr -> S.Set Ident -> NL Qual -> NL Qual
insertGuard guardExpr initialEnv quals = go initialEnv quals
  where
    go :: S.Set Ident -> NL Qual -> NL Qual
    go env (S q)             = 
        if all (\v -> S.member v env) fvs
        then GuardQ guardExpr :* S q
        else q :* (S $ GuardQ guardExpr)
    go env (q@(BindQ x _) :* qs) = 
        if all (\v -> S.member v env) fvs
        then GuardQ guardExpr :* q :* qs
        else q :* go (S.insert x env) qs
    go _ (GuardQ _ :* _)      = $impossible

    fvs = freeVars guardExpr

------------------------------------------------------------------------
-- Generic iterator that merges guards into generators one by one.

data Comp = C Type Expr (NL Qual)

fromQual :: Qual -> Either Qual Expr
fromQual (BindQ x e) = Left $ BindQ x e
fromQual (GuardQ p)  = Right p

type MergeGuard = Comp -> Expr -> [Expr] -> [Expr] -> TranslateC () (Comp, [Expr], [Expr])

tryGuards :: MergeGuard
          -> Comp 
          -> [Expr] 
          -> [Expr] 
          -> TranslateC () (Comp, [Expr])
-- Try the next guard
tryGuards mergeGuardR comp (p : ps) testedGuards = do
    let tryNextGuard :: TranslateC () (Comp, [Expr])
        tryNextGuard = do
            -- Try to combine p with some generators
            (comp', ps', testedGuards') <- mergeGuardR comp p ps testedGuards
            
            -- If we succeeded for p, try the remaining guards.
            (tryGuards mergeGuardR comp' ps' testedGuards')

            -- Even if we failed for the remaining guards, we report a success,
            -- since we succeeded for p
              <+ (return (comp', ps' ++ testedGuards'))

        -- If the current guard failed, try the next ones.
        tryOtherGuards :: TranslateC () (Comp, [Expr])
        tryOtherGuards = tryGuards mergeGuardR comp ps (p : testedGuards)

    tryNextGuard <+ tryOtherGuards
        
-- No guards left to try and none succeeded
tryGuards _ _ [] _ = fail "no predicate could be merged"

mergeStepR :: MergeGuard -> RewriteC (Comp, [Expr])
mergeStepR mergeGuardR = do
    (comp, guards) <- idR
    constT (return ()) >>> tryGuards mergeGuardR comp guards []

-- | Try to build flat joins (equi-, semi- and antijoins) from a
-- comprehensions qualifier list.
-- FIXME only try on those predicates that look like equi-/anti-/semi-join predicates.
mergeGuardsIterR :: MergeGuard -> RewriteC CL
mergeGuardsIterR mergeGuardR = do
    ExprCL (Comp ty e qs) <- idR
    
    -- Separate generators from guards
    ((g : gs), guards@(_:_)) <- return $ partitionEithers $ map fromQual $ toList qs

    let initArg = (C ty e (fromListSafe g gs), guards)

    -- Iteratively try to form joins until we reach a fixed point
    (C _ e' qs', remGuards) <- constT (return initArg) >>> repeatR (mergeStepR mergeGuardR)

    -- If there are any guards remaining which we could not turn into
    -- joins, append them at the end of the new qualifier list
    case remGuards of
        rg : rgs -> let rqs = fmap GuardQ $ fromListSafe rg rgs
                    in return $ ExprCL $ Comp ty e' (appendNL qs' rqs)
        []       -> return $ ExprCL $ Comp ty e' qs'

--------------------------------------------------------------------------------
-- Traversal functions

-- | Traverse the spine of a NL list top-down and apply the translation as soon
-- as possible.
onetdSpineT 
  :: (ReadPath c Int, MonadCatch m, Walker c CL) 
  => Translate c m CL b 
  -> Translate c m CL b
onetdSpineT t = do
    n <- idR
    case n of
        QualsCL (_ :* _) -> childT 0 t <+ childT 1 (onetdSpineT t)
        QualsCL (S _)    -> childT 0 t
        _                -> $impossible

--------------------------------------------------------------------------------
-- Simple debugging combinators

-- | trace output of the value being rewritten; use for debugging only.
prettyR :: (Monad m, Pretty a) => String -> Rewrite c m a
prettyR msg = acceptR (\ a -> trace (msg ++ pp a) True)
           
debug :: Pretty a => String -> a -> b -> b
debug msg a b =
    trace ("\n" ++ msg ++ " =>\n" ++ pp a) b

debugPretty :: (Pretty a, Monad m) => String -> a -> m ()
debugPretty msg a = debug msg a (return ())

debugMsg :: Monad m => String -> m ()
debugMsg msg = trace msg $ return ()

debugOpt :: Expr -> Either String Expr -> Expr
debugOpt origExpr mExpr =
    trace (showOrig origExpr)
    $ either (flip trace origExpr) (\e -> trace (showOpt e) e) mExpr
    
  where 
    showOrig :: Expr -> String
    showOrig e =
        "\nOriginal query ====================================================================\n"
        ++ pp e 
        ++ "\n==================================================================================="
        
    showOpt :: Expr -> String
    showOpt e =
        "Optimized query ===================================================================\n"
        ++ pp e 
        ++ "\n===================================================================================="
        
debugPipeR :: (Monad m, Pretty a) => Rewrite c m a -> Rewrite c m a
debugPipeR r = prettyR "Before >>>>>>"
               >>> r
               >>> prettyR ">>>>>>> After"
               
debugTrace :: Monad m => String -> Rewrite c m a
debugTrace msg = trace msg idR

debugShow :: (Monad m, Pretty a) => String -> Rewrite c m a
debugShow msg = prettyR (msg ++ "\n")

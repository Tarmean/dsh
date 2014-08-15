{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}

module Database.DSH.Optimizer.TA.Rewrite.Basic where

import           Debug.Trace
import           Text.Printf

import           Control.Applicative
import           Control.Monad
import           Data.Either.Combinators
import           Data.Maybe
import qualified Data.Set.Monad                             as S

import           Database.Algebra.Dag.Common
import           Database.Algebra.Table.Lang

import           Database.DSH.Impossible
import           Database.DSH.Optimizer.Common.Rewrite
import           Database.DSH.Optimizer.TA.Properties.Types
import           Database.DSH.Optimizer.TA.Rewrite.Common

cleanup :: TARewrite Bool
cleanup = iteratively $ sequenceRewrites [ applyToAll noProps cleanupRules
                                         , applyToAll inferAll cleanupRulesTopDown
                                         ]

cleanupRules :: TARuleSet ()
cleanupRules = [ stackedProject
               , serializeProject
               , pullProjectWinFun
               , pullProjectSelect
               ]

cleanupRulesTopDown :: TARuleSet AllProps
cleanupRulesTopDown = [ unreferencedRownum
                      , unreferencedRank
                      , unreferencedProjectCols
                      , unreferencedAggrCols
                      , postFilterRownum
                      , inlineSortColsRownum
                      , inlineSortColsSerialize
                      , inlineSortColsWinFun
                      ]

----------------------------------------------------------------------------------
-- Rewrite rules

-- | Eliminate rownums which re-generate positions based on one
-- sorting column. These rownums typically occur after filtering
-- operators, i.e. select, antijoin, semijoin. If the absolute values
-- generated by the rownum are not required and only the encoded order
-- is relevant, we can safely remove the rownum and use the sorting
-- column. In that case, positions might not be dense anymore.
postFilterRownum :: TARule AllProps
postFilterRownum q =
  $(dagPatMatch 'q "RowNum args (q1)"
    [| do
        (res, [(ColE sortCol, _)], []) <- return $(v "args")
        useCols <- pUse <$> td <$> properties q
        keys    <- pKeys <$> bu <$> properties $(v "q1")
        cols    <- pCols <$> bu <$> properties $(v "q1")

        -- To get rid of the rownum, the absolute values generated by
        -- it must not be required.
        predicate $ not $ res `S.member` useCols

        -- Rownum produces a key. If we remove the rownum because its
        -- absolute values are not needed and replace it with the
        -- original sorting column, it should still be a key.
        predicate $ (S.singleton sortCol) `S.member` keys

        -- If we reuse a sorting column, it's type should be int.
        predicate $ AInt == typeOf sortCol cols

        return $ do
          logRewrite "Basic.Rownum.Unused" q
          let projs = (res, ColE sortCol) : map (\c -> (c, ColE c)) (map fst $ S.toList cols)
          void $ replaceWithNew q $ UnOp (Project projs) $(v "q1") |])


---------------------------------------------------------------------------
-- ICols rewrites

-- | Prune a rownumber operator if its output is not required
unreferencedRownum :: TARule AllProps
unreferencedRownum q =
  $(dagPatMatch 'q "RowNum args (q1)"
    [| do
         (res, _, _) <- return $(v "args")
         neededCols  <- pICols <$> td <$> properties q
         predicate $ not (res `S.member` neededCols)

         return $ do
           logRewrite "Basic.ICols.Rownum" q
           replace q $(v "q1") |])

-- | Prune a rownumber operator if its output is not required
unreferencedRank :: TARule AllProps
unreferencedRank q =
  $(dagPatMatch 'q "[Rank | RowRank] args (q1)"
    [| do
         (res, _) <- return $(v "args")
         neededCols  <- pICols <$> td <$> properties q
         predicate $ not (res `S.member` neededCols)

         return $ do
           logRewrite "Basic.ICols.Rank" q
           replace q $(v "q1") |])

-- | Prune projections from a project operator if the result columns
-- are not required.
unreferencedProjectCols :: TARule AllProps
unreferencedProjectCols q =
  $(dagPatMatch 'q "Project projs (q1)"
    [| do
        neededCols <- pICols <$> td <$> properties q
        let neededProjs = filter (flip S.member neededCols . fst) $(v "projs")

        -- Only modify the project if we could actually get rid of some columns.
        predicate $ length neededProjs < length $(v "projs")

        return $ do
          logRewrite "Basic.ICols.Project" q
          void $ replaceWithNew q $ UnOp (Project neededProjs) $(v "q1") |])

-- | Remove aggregate functions whose output is not referenced.
unreferencedAggrCols :: TARule AllProps
unreferencedAggrCols q =
  $(dagPatMatch 'q "Aggr args (q1)"
    [| do
        neededCols <- pICols <$> td <$> properties q
        (aggrs, partCols) <- return $(v "args")

        let neededAggrs = filter (flip S.member neededCols . snd) aggrs

        predicate $ length neededAggrs < length aggrs

        return $ do
          case neededAggrs of
              -- If the output of all aggregate functions is not
              -- required, we can replace it with a distinct operator
              -- on the grouping columns.
              [] -> do
                  logRewrite "Basic.ICols.Aggr.Prune" q
                  projectNode <- insert $ UnOp (Project partCols) $(v "q1")
                  void $ replaceWithNew q $ UnOp (Distinct ()) projectNode

              -- Otherwise, we just prune the unreferenced aggregate functions
              _ : _ -> do
                  logRewrite "Basic.ICols.Aggr.Narrow" q
                  void $ replaceWithNew q $ UnOp (Aggr (neededAggrs, partCols)) $(v "q1") |])

----------------------------------------------------------------------------------
-- Basic Const rewrites

{-
isConstExpr :: Expr -> TAMatch AllProps
isConstExpr (BinAppE _ e1 e2) = (&&) <$> isConstExpr e1 <*> isConstExpr e2
isConstExpr (UnAppE _ e1)     = isConstExpr e1
isConstExpr (ConstE _)        = return True
isConstExpr (IfE e1 e2 e3)    = and <$> mapM isConstExpr [e1, e2, e3]
isConstExpr (ColE c)          = do
    properties $(v "

-- | Prune const columns from aggregation keys
constAggrKey :: TARule AllProps
constAggrKey q =
  $(dagPatMatch 'q "Aggr args (q1)"
    [| do
         (aggrFuns, keyCols@(_:_)) <- return $(v "args")
         keyCols' <- filterM (\(_, e) -> not <$> isConstExpr e) keyCols
         predicate $ length keyCols' < length keyCols

         return $ do
             logRewrite "Basic.Const.Aggr" q
             void $ replaceWithNew q $ UnOp (Aggr ($(v "aggrFuns"), keyCols')) $(v "q1") |])
-}

----------------------------------------------------------------------------------
-- Basic Order rewrites

-- | @lookupSortCol@ returns @Left@ if there is no mapping from the
-- original sort column and @Right@ if there is a mapping from the
-- original sort column to a list of columns that define the same
-- order.
lookupSortCol :: SortSpec -> Orders -> TAMatch AllProps (Either [SortSpec] [SortSpec])
lookupSortCol (ColE oldSortCol, Asc) os =
    case lookup oldSortCol os of
        Nothing          -> return $ Left [(ColE oldSortCol, Asc)]
        Just newSortCols -> return $ Right $ map (\c -> (ColE c, Asc)) newSortCols
lookupSortCol (_, Asc)               _  = fail "only consider column expressions for now"
lookupSortCol (_, Desc)              _  = fail "only consider ascending orders"

inlineSortColsRownum :: TARule AllProps
inlineSortColsRownum q =
  $(dagPatMatch 'q "RowNum o (q1)"
    [| do
        (resCol, sortCols@(_:_), []) <- return $(v "o")

        orders@(_:_) <- pOrder <$> bu <$> properties $(v "q1")

        -- For each sorting column, try to find the original
        -- order-defining sorting columns.
        mSortCols <- mapM (flip lookupSortCol orders) sortCols

        -- The rewrite should only fire if something actually changes
        predicate $ any isRight mSortCols

        let sortCols' = concatMap (either id id) mSortCols

        return $ do
          logRewrite "Basic.InlineOrder.RowNum" q
          void $ replaceWithNew q $ UnOp (RowNum (resCol, sortCols', [])) $(v "q1") |])

inlineSortColsSerialize :: TARule AllProps
inlineSortColsSerialize q =
  $(dagPatMatch 'q "Serialize scols (q1)"
    [| do
        (d, RelPos cs, reqCols) <- return $(v "scols")
        orders@(_:_) <- pOrder <$> bu <$> properties $(v "q1")

        let cs' = concatMap (\c -> maybe [c] id $ lookup c orders) cs
        predicate $ cs /= cs'

        return $ do
            logRewrite "Basic.InlineOrder.Serialize" q
            void $ replaceWithNew q $ UnOp (Serialize (d, RelPos cs', reqCols)) $(v "q1") |])

inlineSortColsWinFun :: TARule AllProps
inlineSortColsWinFun q =
  $(dagPatMatch 'q "WinFun args (q1)"
    [| do
        let (f, part, sortCols, frameSpec) = $(v "args")

        orders@(_:_) <- pOrder <$> bu <$> properties $(v "q1")

        -- For each sorting column, try to find the original
        -- order-defining sorting columns.
        mSortCols <- mapM (flip lookupSortCol orders) sortCols

        -- The rewrite should only fire if something actually changes
        predicate $ any isRight mSortCols

        let sortCols' = concatMap (either id id) mSortCols
            args'     = (f, part, sortCols', frameSpec)

        return $ do
            logRewrite "Basic.InlineOrder.WinFun" q
            void $ replaceWithNew q $ UnOp (WinFun args') $(v "q1") |])

----------------------------------------------------------------------------------
-- Serialize rewrites

-- | Merge a projection which only maps columns into a Serialize operator.
serializeProject :: TARule ()
serializeProject q =
    $(dagPatMatch 'q "Serialize scols (Project projs (q1))"
      [| do
          (d, p, reqCols) <- return $(v "scols")

          let projCol (c', ColE c) = return (c', c)
              projCol _            = fail "no match"

              lookupFail x xys = case lookup x xys of
                  Just y  -> return y
                  Nothing -> fail "no match"

          colMap <- mapM projCol $(v "projs")

          -- find new names for all required columns
          reqCols' <- mapM (\(PayloadCol c) -> PayloadCol <$> lookupFail c colMap) reqCols

          -- find new name for the descriptor column (if required)
          d' <- case d of
              Just (DescrCol c)  -> Just <$> DescrCol <$> lookupFail c colMap
              Nothing            -> return Nothing

          -- find new name for the pos column (if required)
          p' <- case p of
              AbsPos c  -> AbsPos <$> lookupFail c colMap
              RelPos cs -> RelPos <$> mapM (flip lookupFail colMap) cs
              NoPos     -> return NoPos

          return $ do
              logRewrite "Basic.Serialize.Project" q
              void $ replaceWithNew q $ UnOp (Serialize (d', p', reqCols')) $(v "q1") |])

--------------------------------------------------------------------------------
-- Pulling projections through other operators and merging them into
-- other operators

inlineExpr :: [Proj] -> Expr -> Expr
inlineExpr proj expr = 
    case expr of
        BinAppE op e1 e2 -> BinAppE op (inlineExpr proj e1) (inlineExpr proj e2)
        UnAppE op e      -> UnAppE op (inlineExpr proj e)
        ColE c           -> fromMaybe (failedLookup c) (lookup c proj)
        ConstE val       -> ConstE val
        IfE c t e        -> IfE (inlineExpr proj c) (inlineExpr proj t) (inlineExpr proj e)
    
  where
    failedLookup :: Attr -> a
    failedLookup c = trace (printf "mergeProjections: column lookup %s failed\n%s\n%s"
                                   c (show expr) (show proj))
                           $impossible

mergeProjections :: [Proj] -> [Proj] -> [Proj]
mergeProjections proj1 proj2 = map (\(c, e) -> (c, inlineExpr proj2 e)) proj1

stackedProject :: TARule ()
stackedProject q =
  $(dagPatMatch 'q "Project ps1 (Project ps2 (qi))"
    [| do
         return $ do
           let ps = mergeProjections $(v "ps1") $(v "ps2")
           logRewrite "Basic.Project.Merge" q
           void $ replaceWithNew q $ UnOp (Project ps) $(v "qi") |])



mapWinFun :: (Expr -> Expr) -> WinFun -> WinFun
mapWinFun f (WinMax e) = WinMax $ f e
mapWinFun f (WinMin e) = WinMin $ f e
mapWinFun f (WinSum e) = WinSum $ f e
mapWinFun f (WinAvg e) = WinAvg $ f e
mapWinFun f (WinAll e) = WinAll $ f e
mapWinFun f (WinAny e) = WinAny $ f e
mapWinFun _ WinCount   = WinCount

mapAggrFun :: (Expr -> Expr) -> AggrType -> AggrType
mapAggrFun f (Max e) = Max $ f e
mapAggrFun f (Min e) = Min $ f e
mapAggrFun f (Sum e) = Sum $ f e
mapAggrFun f (Avg e) = Avg $ f e
mapAggrFun f (All e) = All $ f e
mapAggrFun f (Any e) = Any $ f e
mapAggrFun _ Count   = Count

pullProjectWinFun :: TARule ()
pullProjectWinFun q =
    $(dagPatMatch 'q "WinFun args (Project proj (q1))"
      [| do
          -- Only consider window functions without partitioning for
          -- now. Partitioning requires proper values and inlining
          -- would be problematic.
          ((resCol, f), [], sortSpec, frameSpec) <- return $(v "args")

          -- If the window function result overwrites one of the
          -- projection columns, we can't pull.
          predicate $ resCol `notElem` (map fst $(v "proj"))

          return $ do
              logRewrite "Basic.PullProject.WinFun" q
              
              -- Merge the projection expressions into window function
              -- arguments and ordering expressions.
              let f'        = mapWinFun (inlineExpr $(v "proj")) f

                  sortSpec' = map (\(e, d) -> (inlineExpr $(v "proj") e, d)) sortSpec

                  proj'     = $(v "proj") ++ [(resCol, ColE resCol)]

              winNode <- insert $ UnOp (WinFun ((resCol, f'), [], sortSpec', frameSpec)) $(v "q1")
              void $ replaceWithNew q $ UnOp (Project proj') winNode |])

pullProjectSelect :: TARule ()
pullProjectSelect q =
    $(dagPatMatch 'q "Select p (Project proj (q1))"
      [| do
          return $ do
              logRewrite "Basic.PullProject.Select" q
              let p' = inlineExpr $(v "proj") $(v "p")
              selectNode <- insert $ UnOp (Select p') $(v "q1")
              void $ replaceWithNew q $ UnOp (Project $(v "proj")) selectNode |])

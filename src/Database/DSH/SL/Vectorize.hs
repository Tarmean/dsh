{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}

module Database.DSH.SL.Vectorize
    ( vectorize
    ) where

import           Control.Monad.Reader

import           Database.Algebra.Dag.Build
import qualified Database.Algebra.Dag.Common    as Alg

import           Database.DSH.Common.Impossible
import           Database.DSH.Common.Lang
import           Database.DSH.Common.QueryPlan
import           Database.DSH.Common.Type
import           Database.DSH.Common.Vector
import qualified Database.DSH.Common.VectorLang as VL
import           Database.DSH.FKL.Lang
import qualified Database.DSH.SL.Builtins       as Builtins
import           Database.DSH.SL.Construct
import qualified Database.DSH.SL.Lang           as SL

--------------------------------------------------------------------------------
-- Extend the DAG builder monad with an environment for compiled SL
-- DAGs.

type Env = [(String, Shape DVec)]

type EnvBuild = ReaderT Env (Build SL.SL)

lookupEnv :: String -> EnvBuild (Shape DVec)
lookupEnv n = ask >>= \env -> case lookup n env of
    Just r -> return r
    Nothing -> $impossible

bind :: Ident -> Shape DVec -> Env -> Env
bind n e env = (n, e) : env

--------------------------------------------------------------------------------
-- Compilation from FKL expressions to a SL DAG.

fkl2SL :: FExpr -> EnvBuild (Shape DVec)
fkl2SL expr =
    case expr of
        Var _ n -> lookupEnv n
        Let _ n e1 e -> do
            e1' <- fkl2SL e1
            local (bind n e1') $ fkl2SL e
        Table _ n schema -> lift $ Builtins.dbTable n schema
        Const t v -> lift $ Builtins.shredLiteral t v
        BinOp _ o NotLifted e1 e2    -> do
            s1 <- fkl2SL e1
            s2 <- fkl2SL e2
            lift $ Builtins.binOp o s1 s2
        BinOp _ o Lifted e1 e2     -> do
            s1 <- fkl2SL e1
            s2 <- fkl2SL e2
            lift $ Builtins.binOpL o s1 s2
        UnOp _ o NotLifted e1 -> do
            SShape p1 lyt <- fkl2SL e1
            p              <- lift $ slUnExpr o p1
            return $ SShape p lyt
        UnOp _ o Lifted e1 -> do
            VShape p1 lyt <- fkl2SL e1
            p                  <- lift $ slUnExpr o p1
            return $ VShape p lyt
        If _ eb e1 e2 -> do
            eb' <- fkl2SL eb
            e1' <- fkl2SL e1
            e2' <- fkl2SL e2
            lift $ Builtins.ifList eb' e1' e2'
        PApp1 t f l arg -> do
            arg' <- fkl2SL arg
            lift $ papp1 t f l arg'
        PApp2 _ f l arg1 arg2 -> do
            arg1' <- fkl2SL arg1
            arg2' <- fkl2SL arg2
            lift $ papp2 f l arg1' arg2'
        PApp3 _ p l arg1 arg2 arg3 -> do
            arg1' <- fkl2SL arg1
            arg2' <- fkl2SL arg2
            arg3' <- fkl2SL arg3
            lift $ papp3 p l arg1' arg2' arg3'
        Ext (Forget n _ arg) -> do
            arg' <- fkl2SL arg
            return $ forget n arg'
        Ext (Imprint n _ arg1 arg2) -> do
            arg1' <- fkl2SL arg1
            arg2' <- fkl2SL arg2
            return $ imprint n arg1' arg2'
        MkTuple _ Lifted args -> do
            args' <- mapM fkl2SL args
            lift $ Builtins.tupleL args'
        MkTuple _ NotLifted args -> do
            args' <- mapM fkl2SL args
            lift $ Builtins.tuple args'

papp3 :: Prim3 -> Lifted -> Shape DVec -> Shape DVec -> Shape DVec -> Build SL.SL (Shape DVec)
papp3 Combine Lifted    = Builtins.combineL
papp3 Combine NotLifted = Builtins.combine

aggL :: Type -> AggrFun -> Shape DVec -> Build SL.SL (Shape DVec)
aggL t Sum     = Builtins.aggrL (VL.AggrSum $ VL.typeToScalarType $ elemT t)
aggL _ Avg     = Builtins.aggrL VL.AggrAvg
aggL _ Maximum = Builtins.aggrL VL.AggrMax
aggL _ Minimum = Builtins.aggrL VL.AggrMin
aggL _ Or      = Builtins.aggrL VL.AggrAny
aggL _ And     = Builtins.aggrL VL.AggrAll
aggL _ Length  = Builtins.lengthL

agg :: Type -> AggrFun -> Shape DVec -> Build SL.SL (Shape DVec)
agg t Sum     = Builtins.aggr (VL.AggrSum $ VL.typeToScalarType t)
agg _ Avg     = Builtins.aggr VL.AggrAvg
agg _ Maximum = Builtins.aggr VL.AggrMax
agg _ Minimum = Builtins.aggr VL.AggrMin
agg _ Or      = Builtins.aggr VL.AggrAny
agg _ And     = Builtins.aggr VL.AggrAll
agg _ Length  = Builtins.length_

translateAggrFun :: AggrApp -> VL.AggrFun
translateAggrFun a = case aaFun a of
    Sum     -> let t = VL.typeToScalarType $ typeOf $ aaArg a
               in VL.AggrSum t e
    Avg     -> VL.AggrAvg e
    Maximum -> VL.AggrMax e
    Minimum -> VL.AggrMin e
    Or      -> VL.AggrAny e
    And     -> VL.AggrAll e
    Length  -> VL.AggrCount
  where
    e = VL.scalarExpr $ aaArg a

papp1 :: Type -> Prim1 -> Lifted -> Shape DVec -> Build SL.SL (Shape DVec)
papp1 t f Lifted =
    case f of
        Singleton       -> Builtins.singletonL
        Only            -> Builtins.onlyL
        Concat          -> Builtins.concatL
        Reverse         -> Builtins.reverseL
        Nub             -> Builtins.nubL
        Number          -> Builtins.numberL
        Sort            -> Builtins.sortL
        Group           -> Builtins.groupL
        Restrict        -> Builtins.restrictL
        Agg a           -> aggL t a
        TupElem i       -> Builtins.tupElemL i

papp1 t f NotLifted =
    case f of
        Singleton        -> Builtins.singleton
        Only             -> Builtins.only
        Number           -> Builtins.number
        Sort             -> Builtins.sort
        Group            -> Builtins.group
        Restrict         -> Builtins.restrict
        Nub              -> Builtins.nub
        Reverse          -> Builtins.reverse
        Concat           -> Builtins.concat
        Agg a            -> agg t a
        TupElem i        -> Builtins.tupElem i

papp2 :: Prim2 -> Lifted -> Shape DVec -> Shape DVec -> Build SL.SL (Shape DVec)
papp2 f Lifted =
    case f of
        Dist                -> Builtins.distL
        Append              -> Builtins.appendL
        Zip                 -> Builtins.zipL
        CartProduct         -> Builtins.cartProductL
        ThetaJoin p         -> Builtins.thetaJoinL p
        NestJoin p          -> Builtins.nestJoinL p
        GroupJoin p (NE as) -> Builtins.groupJoinL p (NE $ fmap translateAggrFun as)
        SemiJoin p          -> Builtins.semiJoinL p
        AntiJoin p          -> Builtins.antiJoinL p

papp2 f NotLifted =
    case f of
        Dist                -> Builtins.dist
        Append              -> Builtins.append
        Zip                 -> Builtins.zip
        CartProduct         -> Builtins.cartProduct
        ThetaJoin p         -> Builtins.thetaJoin p
        NestJoin p          -> Builtins.nestJoin p
        GroupJoin p (NE as) -> Builtins.groupJoin p (NE $ fmap translateAggrFun as)
        SemiJoin p          -> Builtins.semiJoin p
        AntiJoin p          -> Builtins.antiJoin p

-- For each top node, determine the number of columns the vector has and insert
-- a dummy projection which just copies those columns. This is to ensure that
-- columns which are required from the top are not pruned by optimizations.
insertTopProjections :: Build SL.SL (Shape DVec) -> Build SL.SL (Shape DVec)
insertTopProjections g = g >>= traverseShape

  where
    traverseShape :: Shape DVec -> Build SL.SL (Shape DVec)
    traverseShape (VShape (DVec q) lyt) =
        insertProj lyt q VShape
    traverseShape (SShape (DVec q) lyt)     =
        insertProj lyt q SShape

    traverseLayout :: Layout DVec -> Build SL.SL (Layout DVec)
    traverseLayout LCol                   = return LCol
    traverseLayout (LTuple lyts)          = LTuple <$> mapM traverseLayout lyts
    traverseLayout (LNest (DVec q) lyt) =
      insertProj lyt q LNest

    insertProj :: Layout DVec                  -- ^ The node's layout
               -> Alg.AlgNode                    -- ^ The top node to consider
               -> (DVec -> Layout DVec -> t) -- ^ Layout/Shape constructor
               -> Build SL.SL t
    insertProj lyt q describe = do
        let width = columnsInLayout lyt
            cols  = [1 .. width]
        qp   <- insert $ Alg.UnOp (SL.Project $ map VL.Column cols) q
        lyt' <- traverseLayout lyt
        return $ describe (DVec qp) lyt'

-- | Compile a FKL expression into a query plan of vector operators (SL)
vectorize :: FExpr -> QueryPlan SL.SL DVec
vectorize e = mkQueryPlan opMap shape tagMap
  where
    (opMap, shape, tagMap) = runBuild (insertTopProjections $ runReaderT (fkl2SL e) [])
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE FlexibleContexts #-}

module Database.DSH.Translate.VL2Algebra
    ( VecBuild
    , runVecBuild
    , vl2Algebra
    ) where

import qualified Data.IntMap                          as IM
import           Data.List
import qualified Data.Map                             as M
import qualified Data.Traversable                     as T

import           Control.Monad.State

import qualified Database.Algebra.Dag                 as D
import qualified Database.Algebra.Dag.Build           as B
import           Database.Algebra.Dag.Common

import           Database.DSH.Common.Impossible
import           Database.DSH.Common.QueryPlan
import           Database.DSH.Translate.FKL2VL        ()
import           Database.DSH.Common.Vector
import qualified Database.DSH.VL.Lang                 as V
import           Database.DSH.VL.VectorAlgebra

-- | A layer on top of the DAG builder monad that caches the
-- translation result of VL nodes.
type VecBuild a d p r = StateT (M.Map AlgNode (Res d p r)) (B.Build a)

runVecBuild :: VectorAlgebra a
            => VecBuild a (DVec a) (PVec a) (RVec a) r
            -> (D.AlgebraDag a, r, NodeMap [Tag])
runVecBuild c = B.runBuild $ fst <$> runStateT c M.empty

data Res d p r = RPVec p
               | RRVec r
               | RDVec d
               | RLPair (Res d p r) (Res d p r)
               | RTriple (Res d p r) (Res d p r) (Res d p r)
         deriving Show

fromDict :: VectorAlgebra a => AlgNode -> VecBuild a d p r (Maybe (Res d p r))
fromDict n = do
    dict <- get
    return $ M.lookup n dict

insertTranslation :: VectorAlgebra a => AlgNode -> Res d p r -> VecBuild a d p r ()
insertTranslation n res = modify (M.insert n res)

fromPVec :: p -> Res d p r
fromPVec p = RPVec p

toPVec :: Res d p r -> p
toPVec (RPVec p) = p
toPVec _         = error "toPVec: Not a prop vector"

fromRVec :: r -> Res d p r
fromRVec r = RRVec r

toRVec :: Res d p r -> r
toRVec (RRVec r) = r
toRVec _         = error "toRVec: Not a rename vector"

fromDVec :: d -> Res d p r
fromDVec v = RDVec v

toDVec :: Res d p r -> d
toDVec (RDVec v) = v
toDVec _         = error "toDVec: Not a NDVec"

-- | Refresh vectors in a shape from the cache.
refreshShape :: VectorAlgebra a => Shape VLDVec -> VecBuild a d p r (Shape d)
refreshShape shape = T.mapM refreshVec shape
  where
    refreshVec (VLDVec n) = do
        mv <- fromDict n
        case mv of
            Just v -> return $ toDVec v
            Nothing -> $impossible

translate :: VectorAlgebra a
          => NodeMap V.VL
          -> AlgNode
          -> VecBuild a (DVec a) (PVec a) (RVec a) (Res (DVec a) (PVec a) (RVec a))
translate vlNodes n = do
    r <- fromDict n

    case r of
        -- The VL node has already been encountered and translated.
        Just res -> return $ res

        -- The VL node has not been translated yet.
        Nothing  -> do
            let vlOp = getVL n vlNodes
            r' <- case vlOp of
                TerOp t c1 c2 c3 -> do
                    c1' <- translate vlNodes c1
                    c2' <- translate vlNodes c2
                    c3' <- translate vlNodes c3
                    lift $ translateTerOp t c1' c2' c3'
                BinOp b c1 c2    -> do
                    c1' <- translate vlNodes c1
                    c2' <- translate vlNodes c2
                    lift $ translateBinOp b c1' c2'
                UnOp u c1        -> do
                    c1' <- translate vlNodes c1
                    lift $ translateUnOp u c1'
                NullaryOp o      -> lift $ translateNullary o

            insertTranslation n r'
            return r'

getVL :: AlgNode -> NodeMap V.VL -> V.VL
getVL n vlNodes = case IM.lookup n vlNodes of
    Just op -> op
    Nothing -> error $ "getVL: node " ++ (show n) ++ " not in VL nodes map " ++ (pp vlNodes)

pp :: NodeMap V.VL -> String
pp m = intercalate ",\n" $ map show $ IM.toList m

vl2Algebra :: VectorAlgebra a
           => NodeMap V.VL
           -> Shape VLDVec
           -> VecBuild a (DVec a) (PVec a) (RVec a) (Shape (DVec a))
vl2Algebra vlNodes plan = do
    mapM_ (translate vlNodes) roots

    refreshShape plan
  where
    roots :: [AlgNode]
    roots = shapeNodes plan

translateTerOp :: VectorAlgebra a
               => V.TerOp
               -> Res (DVec a) (PVec a) (RVec a)
               -> Res (DVec a) (PVec a) (RVec a)
               -> Res (DVec a) (PVec a) (RVec a)
               -> B.Build a (Res (DVec a) (PVec a) (RVec a))
translateTerOp t c1 c2 c3 =
    case t of
        V.Combine -> do
            (d, r1, r2) <- vecCombine (toDVec c1) (toDVec c2) (toDVec c3)
            return $ RTriple (fromDVec d) (fromRVec r1) (fromRVec r2)

translateBinOp :: VectorAlgebra a
               => V.BinOp
               -> Res (DVec a) (PVec a) (RVec a)
               -> Res (DVec a) (PVec a) (RVec a)
               -> B.Build a (Res (DVec a) (PVec a) (RVec a))
translateBinOp b c1 c2 = case b of
    V.DistLift -> do
        (v, p) <- vecDistLift (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromPVec p)

    V.PropRename -> fromDVec <$> vecPropRename (toRVec c1) (toDVec c2)

    V.PropFilter -> do
        (v, r) <- vecPropFilter (toRVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromRVec r)

    V.PropReorder -> do
        (v, p) <- vecPropReorder (toPVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromPVec p)

    V.UnboxNested -> do
        (v, r) <- vecUnboxNested (toRVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromRVec r)

    V.UnboxScalar -> RDVec <$> vecUnboxScalar (toDVec c1) (toDVec c2)

    V.Append -> do
        (v, r1, r2) <- vecAppend (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromRVec r1) (fromRVec r2)

    V.AppendS -> do
        (v, r1, r2) <- vecAppendS (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromRVec r1) (fromRVec r2)

    V.AggrS a -> fromDVec <$> vecAggrS a (toDVec c1) (toDVec c2)


    V.SelectPos o -> do
        (v, r, ru) <- vecSelectPos (toDVec c1) o (toDVec c2)
        return $ RTriple (fromDVec v) (fromRVec r) (fromRVec ru)

    V.SelectPosS o -> do
        (v, rp, ru) <- vecSelectPosS (toDVec c1) o (toDVec c2)
        return $ RTriple (fromDVec v) (fromRVec rp) (fromRVec ru)

    V.Zip -> fromDVec <$> vecZip (toDVec c1) (toDVec c2)
    V.Align -> fromDVec <$> vecZip (toDVec c1) (toDVec c2)

    V.ZipS -> do
        (v, r1 ,r2) <- vecZipS (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromRVec r1) (fromRVec r2)

    V.CartProduct -> do
        (v, p1, p2) <- vecCartProduct (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromPVec p1) (fromPVec p2)

    V.CartProductS -> do
        (v, p1, p2) <- vecCartProductS (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromPVec p1) (fromPVec p2)

    V.NestProductS -> do
        (v, p2) <- vecNestProductS (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromPVec p2)

    V.ThetaJoin p -> do
        (v, p1, p2) <- vecThetaJoin p (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromPVec p1) (fromPVec p2)

    V.NestProduct -> do
        (v, p1, p2) <- vecNestProduct (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromPVec p1) (fromPVec p2)

    V.NestJoin p -> do
        (v, p1, p2) <- vecNestJoin p (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromPVec p1) (fromPVec p2)

    V.ThetaJoinS p -> do
        (v, p1, p2) <- vecThetaJoinS p (toDVec c1) (toDVec c2)
        return $ RTriple (fromDVec v) (fromPVec p1) (fromPVec p2)

    V.NestJoinS p -> do
        (v, p2) <- vecNestJoinS p (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromPVec p2)

    V.GroupJoin (p, a) -> fromDVec <$> vecGroupJoin p a (toDVec c1) (toDVec c2)

    V.SemiJoin p -> do
        (v, r) <- vecSemiJoin p (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromRVec r)

    V.SemiJoinS p -> do
        (v, r) <- vecSemiJoinS p (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromRVec r)

    V.AntiJoin p -> do
        (v, r) <- vecAntiJoin p (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromRVec r)

    V.AntiJoinS p -> do
        (v, r) <- vecAntiJoinS p (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec v) (fromRVec r)

    V.TransposeS -> do
        (qo, qi) <- vecTransposeS (toDVec c1) (toDVec c2)
        return $ RLPair (fromDVec qo) (fromDVec qi)

translateUnOp :: VectorAlgebra a
              => V.UnOp
              -> Res (DVec a) (PVec a) (RVec a)
              -> B.Build a (Res (DVec a) (PVec a) (RVec a))
translateUnOp unop c = case unop of
    V.AggrNonEmptyS a  -> fromDVec <$> vecAggrNonEmptyS a (toDVec c)
    V.UniqueS          -> fromDVec <$> vecUniqueS (toDVec c)
    V.Number           -> fromDVec <$> vecNumber (toDVec c)
    V.NumberS          -> fromDVec <$> vecNumberS (toDVec c)
    V.UnboxRename      -> fromRVec <$> descToRename (toDVec c)
    V.Segment          -> fromDVec <$> vecSegment (toDVec c)
    V.Unsegment        -> fromDVec <$> vecUnsegment (toDVec c)
    V.Aggr a           -> fromDVec <$> vecAggr a (toDVec c)
    V.WinFun  (a, w)   -> fromDVec <$> vecWinFun a w (toDVec c)
    V.AggrNonEmpty as  -> fromDVec <$> vecAggrNonEmpty as (toDVec c)
    V.Select e         -> do
        (d, r) <- vecSelect e (toDVec c)
        return $ RLPair (fromDVec d) (fromRVec r)
    V.Sort es         -> do
        (d, p) <- vecSort es (toDVec c)
        return $ RLPair (fromDVec d) (fromPVec p)
    V.SortS es         -> do
        (d, p) <- vecSortS es (toDVec c)
        return $ RLPair (fromDVec d) (fromPVec p)
    V.Group es -> do
        (qo, qi, p) <- vecGroup es (toDVec c)
        return $ RTriple (fromDVec qo) (fromDVec qi) (fromPVec p)
    V.GroupS es -> do
        (qo, qi, p) <- vecGroupS es (toDVec c)
        return $ RTriple (fromDVec qo) (fromDVec qi) (fromPVec p)
    V.Project cols -> fromDVec <$> vecProject cols (toDVec c)
    V.Reverse      -> do
        (d, p) <- vecReverse (toDVec c)
        return $ RLPair (fromDVec d) (fromPVec p)
    V.ReverseS      -> do
        (d, p) <- vecReverseS (toDVec c)
        return $ RLPair (fromDVec d) (fromPVec p)
    V.SelectPos1 (op, pos) -> do
        (d, p, u) <- vecSelectPos1 (toDVec c) op pos
        return $ RTriple (fromDVec d) (fromRVec p) (fromRVec u)
    V.SelectPos1S (op, pos) -> do
        (d, p, u) <- vecSelectPos1S (toDVec c) op pos
        return $ RTriple (fromDVec d) (fromRVec p) (fromRVec u)
    V.GroupAggr (g, as) -> fromDVec <$> vecGroupAggr g as (toDVec c)

    V.Reshape n -> do
        (qo, qi) <- vecReshape n (toDVec c)
        return $ RLPair (fromDVec qo) (fromDVec qi)
    V.ReshapeS n -> do
        (qo, qi) <- vecReshapeS n (toDVec c)
        return $ RLPair (fromDVec qo) (fromDVec qi)
    V.Transpose -> do
        (qo, qi) <- vecTranspose (toDVec c)
        return $ RLPair (fromDVec qo) (fromDVec qi)
    V.R1            -> case c of
        (RLPair c1 _)     -> return c1
        (RTriple c1 _ _) -> return c1
        _                -> error "R1: Not a tuple"
    V.R2            -> case c of
        (RLPair _ c2)     -> return c2
        (RTriple _ c2 _) -> return c2
        _                -> error "R2: Not a tuple"
    V.R3            -> case c of
        (RTriple _ _ c3) -> return c3
        _                -> error "R3: Not a tuple"

translateNullary :: VectorAlgebra a
                 => V.NullOp
                 -> B.Build a (Res (DVec a) (PVec a) (RVec a))
translateNullary V.SingletonDescr          = fromDVec <$> singletonDescr
translateNullary (V.Lit (_, tys, vals))    = fromDVec <$> vecLit tys vals
translateNullary (V.TableRef (n, schema))  = fromDVec <$> vecTableRef n schema

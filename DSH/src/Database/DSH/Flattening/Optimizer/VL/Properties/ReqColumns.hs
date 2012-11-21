module Optimizer.VL.Properties.ReqColumns where

import           Data.List
import           Database.Algebra.VL.Data
import           Optimizer.VL.Properties.Types

unp :: Show a => VectorProp a -> a
unp (VProp x) = x
unp x         = error $ "ReqColumns.unp " ++ (show x)

colUnion :: VectorProp ReqCols -> VectorProp ReqCols -> VectorProp ReqCols
colUnion (VProp (Just cols1)) (VProp (Just cols2)) = VProp $ Just $ cols1 `union` cols2
colUnion (VProp (Just cols1)) (VProp Nothing)      = VProp $ Just $ cols1
colUnion (VProp Nothing)      (VProp (Just cols2)) = VProp $ Just $ cols2
colUnion (VProp Nothing)      (VProp Nothing)      = VProp $ Nothing
colUnion p1                   p2                   = error ("ReqColumns.colUnion" ++ " " ++ (show p1) ++ " " ++ (show p2))

none :: VectorProp ReqCols
none = VProp $ Just []

one :: VectorProp ReqCols
one = VProp $ Just [1]

na :: VectorProp ReqCols
na = VProp Nothing

reqProjCols :: [PayloadProj] -> [DBCol]
reqProjCols ((PLCol col) : ps) = col : (reqProjCols ps)
reqProjCols ((PLConst _) : ps) = reqProjCols ps
reqProjCols []                 = []

reqExpr1Cols :: Expr1 -> [DBCol]
reqExpr1Cols (App1 _ e1 e2) = reqExpr1Cols e1 `union` reqExpr1Cols e2
reqExpr1Cols (Column1 col)  = [col]
reqExpr1Cols (Constant1 _)  = []

reqExpr2ColsLeft :: Expr2 -> [DBCol]
reqExpr2ColsLeft (App2 _ e1 e2)        = reqExpr2ColsLeft e1 `union` reqExpr2ColsLeft e2
reqExpr2ColsLeft (Column2Left (L col)) = [col]
reqExpr2ColsLeft (Column2Right _)      = []
reqExpr2ColsLeft (Constant2 _)         = []

reqExpr2ColsRight :: Expr2 -> [DBCol]
reqExpr2ColsRight (App2 _ e1 e2)         = reqExpr2ColsRight e1 `union` reqExpr2ColsRight e2
reqExpr2ColsRight (Column2Right (R col)) = [col]
reqExpr2ColsRight (Column2Left _)        = []
reqExpr2ColsRight (Constant2 _)          = []

inferReqColumnsUnOp :: VectorProp ReqCols
                -> VectorProp ReqCols
                -> UnOp
                -> VectorProp ReqCols
inferReqColumnsUnOp ownReqColumns childReqColumns op =
  case op of
    ToDescr          -> colUnion childReqColumns none

    Unique -> colUnion ownReqColumns childReqColumns

    UniqueL -> colUnion ownReqColumns childReqColumns

    NotPrim -> one

    NotVec -> one

    LengthA -> colUnion ownReqColumns childReqColumns

    DescToRename -> na

    Segment -> colUnion ownReqColumns childReqColumns

    VecSum _ -> one

    VecMin -> one

    VecMinL -> one

    VecMax -> one
    VecMaxL -> one

    ProjectL cols -> colUnion childReqColumns (VProp $ Just cols)
    ProjectA cols -> colUnion childReqColumns (VProp $ Just cols)

    IntegerToDoubleA -> one
    IntegerToDoubleL -> one

    ReverseA -> colUnion ownReqColumns childReqColumns
    ReverseL -> colUnion ownReqColumns childReqColumns

    FalsePositions -> one

    ProjectRename _ -> none

    ProjectPayload ps -> colUnion childReqColumns (VProp $ Just $ reqProjCols ps)

    ProjectAdmin _ -> colUnion ownReqColumns childReqColumns

    SelectExpr e -> colUnion childReqColumns (VProp $ Just $ reqExpr1Cols e)

    CompExpr1L e -> colUnion childReqColumns (VProp $ Just $ reqExpr1Cols e)

    SelectPos1 _ _   ->
      case ownReqColumns of
        VPropPair cols _ -> colUnion childReqColumns (VProp cols)
        _                           -> error "SelectPos1"

    SelectPos1L _ _   ->
      case ownReqColumns of
        VPropPair cols _ -> colUnion childReqColumns (VProp cols)
        _                -> error "SelectPos1L"

    R1               ->
      case childReqColumns of
        VProp _                       -> error $ "ReqColumns.R1 " ++ (show childReqColumns)
        VPropPair cols1 cols2         -> VPropPair (unp (colUnion (VProp cols1) ownReqColumns)) cols2
        VPropTriple cols1 cols2 cols3 -> VPropTriple (unp (colUnion (VProp cols1) ownReqColumns)) cols2 cols3

    R2               ->
      case childReqColumns of
        VProp _              -> error "ReqColumns.R2"
        VPropPair cols1 cols2      -> VPropPair cols1 (unp (colUnion (VProp cols2) ownReqColumns))
        VPropTriple cols1 cols2 cols3 -> VPropTriple cols1 (unp (colUnion (VProp cols2) ownReqColumns)) cols3
    R3               ->
      case childReqColumns of
        VProp _              -> error "ReqColumns.R3/1"
        VPropPair _ _        -> error "ReqColumns.R3/2"
        VPropTriple cols1 cols2 cols3 -> VPropTriple cols1 cols2 (unp (colUnion (VProp cols3) ownReqColumns))

    Only -> undefined
    Singleton -> undefined

allCols :: BottomUpProps -> VectorProp ReqCols
allCols props = case vectorTypeProp props of
                 (VProp (ValueVector w)) -> VProp $ Just [1 .. w]
                 _                       -> error "ReqColumns.allCols: ValueVector expected"

inferReqColumnsBinOp :: BottomUpProps
                        -> BottomUpProps
                        -> VectorProp ReqCols
                        -> VectorProp ReqCols
                        -> VectorProp ReqCols
                        -> BinOp
                        -> (VectorProp ReqCols, VectorProp ReqCols)
inferReqColumnsBinOp childBUProps1 childBUProps2 ownReqColumns childReqColumns1 childReqColumns2 op =
  case op of
    GroupBy         ->
      case ownReqColumns of
        VPropTriple _ cols _ -> (allCols childBUProps1, colUnion childReqColumns2 (VProp cols))
        _                    -> undefined -- FIXME

    SortWith        ->
      case ownReqColumns of
        VPropPair cols _  -> (allCols childBUProps1, colUnion childReqColumns2 (VProp cols))
        _                 -> undefined -- FIXME

    LengthSeg -> (none, none)

    DistPrim -> (na, na)

    DistDesc ->
      case ownReqColumns of
        VPropPair cols _ -> (colUnion (VProp cols) childReqColumns1, na)
        _                -> error "DistDesc"

    DistLift ->
      case ownReqColumns of
        VPropPair cols _ -> (colUnion (VProp cols) childReqColumns1, VProp Nothing)
        _                -> error "DistLift"

    PropRename      -> (na, colUnion childReqColumns2 ownReqColumns)

    PropFilter      ->
      case ownReqColumns of
        VPropPair cols _ -> (na, colUnion childReqColumns2 (VProp cols))
        _                -> error "PropFilter"

    PropReorder ->
      case ownReqColumns of
        VPropPair cols _ -> (na, colUnion (VProp cols) childReqColumns2)
        _              -> error "PropReorder"

    Append ->
      case ownReqColumns of
        VPropTriple cols _ _ -> (colUnion (VProp cols) childReqColumns1, colUnion (VProp cols) childReqColumns2)
        _                    -> error "Append"

    RestrictVec ->
      case ownReqColumns of
        VPropPair cols _ -> (colUnion (VProp cols) childReqColumns1, one)
        _                -> error "RestrictVec"


    CompExpr2 e ->
      let reqColsLeft  = colUnion (VProp $ Just $ reqExpr2ColsLeft e) childReqColumns1
          reqColsRight = colUnion (VProp $ Just $ reqExpr2ColsRight e) childReqColumns2
      in (reqColsLeft, reqColsRight)

    CompExpr2L e ->
      let reqColsLeft  = colUnion (VProp $ Just $ reqExpr2ColsLeft e) childReqColumns1
          reqColsRight = colUnion (VProp $ Just $ reqExpr2ColsRight e) childReqColumns2
      in (reqColsLeft, reqColsRight)

    VecSumL -> (na, one)

    SelectPos _ ->
      case ownReqColumns of
        VPropPair cols _ -> (colUnion (VProp cols) childReqColumns1, na)
        _                -> error "SelectPos"
    SelectPosL _ ->
      case ownReqColumns of
        VPropPair cols _ -> (colUnion (VProp cols) childReqColumns1, na)
        _                -> error "SelectPosL"

    PairA -> partitionCols childBUProps1 childBUProps2 (unp ownReqColumns)

    PairL -> partitionCols childBUProps1 childBUProps2 (unp ownReqColumns)

    CartProduct ->
      case ownReqColumns of
        VPropTriple cols1 _ _ -> partitionCols childBUProps1 childBUProps2 cols1
        _                     -> error "ReqColumns.CartProduct"

    ThetaJoin    _ -> partitionCols childBUProps1 childBUProps2 (unp ownReqColumns)

    ZipL -> partitionCols childBUProps1 childBUProps2 (unp ownReqColumns) -- FIXME recheck for correctness

partitionCols :: BottomUpProps -> BottomUpProps -> ReqCols -> (VectorProp ReqCols, VectorProp ReqCols)
partitionCols childBUProps1 childBUProps2 ownReqCols =
  let childType1 = unp $ vectorTypeProp childBUProps1
      childType2 = unp $ vectorTypeProp childBUProps2
  in
   case ownReqCols of
     Just cols ->
       case (childType1, childType2) of
         -- If both inputs are ValueVectors, map the required columns to the respective inputs
         (ValueVector w1, ValueVector w2) ->
           let leftReqCols  = cols `intersect` [1 .. w1]
               rightReqCols = cols `intersect` [(w1 + 1) .. (w1 + w2)]
           in (VProp $ Just leftReqCols, VProp $ Just rightReqCols)
         -- If only one input is a ValueVector, map the required columns to this input.
         (ValueVector w1, DescrVector) ->
           let leftReqCols  = cols `intersect` [1 .. w1]
           -- FIXME should the right side be na or none?
           in (VProp $ Just leftReqCols, na)
         (DescrVector, ValueVector w2) ->
           let rightReqCols = cols `intersect` [1 .. w2]
           -- FIXME should the left side be na or none?
           in (na, VProp $ Just rightReqCols)
         _                                -> error ("partitionCols " ++ (show childType1) ++ " " ++ (show childType2))
     Nothing -> (na, na)



inferReqColumnsTerOp :: VectorProp ReqCols
                 -> VectorProp ReqCols
                 -> VectorProp ReqCols
                 -> VectorProp ReqCols
                 -> TerOp
                 -> (VectorProp ReqCols, VectorProp ReqCols, VectorProp ReqCols)
inferReqColumnsTerOp ownReqColumns _ childReqColumns2 _ op =
  case op of
    CombineVec ->
      case ownReqColumns of
        VPropTriple cols _ _ -> (one, colUnion (VProp cols) childReqColumns2, colUnion (VProp cols) childReqColumns2)
        _                    -> error "CombineVec"

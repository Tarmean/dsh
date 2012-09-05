module Optimizer.VL.Properties.BottomUp where

import Text.PrettyPrint

import qualified Data.Map as M

import Database.Algebra.Dag
import Database.Algebra.Dag.Common
import Database.Algebra.VL.Data

import Optimizer.Common.Aux
import Optimizer.VL.Properties.Types
import Optimizer.VL.Properties.Empty
import Optimizer.VL.Properties.VectorType
import Optimizer.VL.Properties.Const
import Optimizer.VL.Properties.Card
-- import Optimizer.VL.Properties.Descriptor

-- FIXME this is (almost) identical to its X100 counterpart -> merge
inferWorker :: NodeMap VL -> AlgNode -> NodeMap BottomUpProps -> NodeMap BottomUpProps
inferWorker nm n pm = 
    let res = 
           case lookupUnsafe nm "no children in nodeMap" n of
                TerOp op c1 c2 c3 -> 
                  let c1Props = lookupUnsafe pm "no children properties" c1
                      c2Props = lookupUnsafe pm "no children properties" c2
                      c3Props = lookupUnsafe pm "no children properties" c3
                  in inferTerOp n op c1Props c2Props c3Props
                BinOp op c1 c2 -> 
                  let c1Props = lookupUnsafe pm "no children properties" c1
                      c2Props = lookupUnsafe pm "no children properties" c2
                  in inferBinOp n op c1Props c2Props
                UnOp op c -> 
                  let cProps = lookupUnsafe pm "no children properties" c
                  in inferUnOp n op cProps
                NullaryOp op -> inferNullOp n op
    in case res of
            Left msg -> error $ "Inference failed at node " ++ (show n) ++ ": " ++ msg
            Right props -> M.insert n props pm
       
inferNullOp :: AlgNode -> NullOp -> Either String BottomUpProps
inferNullOp _ op = do
  opEmpty <- inferEmptyNullOp op
  opConst <- inferConstVecNullOp op
  opType <- inferVectorTypeNullOp op
  opCard <- inferCardOneNullOp op
  return $ BUProps { emptyProp = opEmpty 
                   , constProp = opConst
                   , card1Prop = opCard
                   , vectorTypeProp = opType }
    
inferUnOp :: AlgNode -> UnOp -> BottomUpProps -> Either String BottomUpProps
inferUnOp _ op cProps = do
  opEmpty <- inferEmptyUnOp (emptyProp cProps) op
  opType <- inferVectorTypeUnOp (vectorTypeProp cProps) op
  opConst <- inferConstVecUnOp (constProp cProps) op
  opCard <- inferCardOneUnOp (card1Prop cProps) op
  return $ BUProps { emptyProp = opEmpty 
                   , constProp = opConst
                   , card1Prop = opCard
                   , vectorTypeProp = opType }
  
inferBinOp :: AlgNode -> BinOp -> BottomUpProps -> BottomUpProps -> Either String BottomUpProps
inferBinOp _ op c1Props c2Props = do
  opEmpty <- inferEmptyBinOp (emptyProp c1Props) (emptyProp c2Props) op
  opType <- inferVectorTypeBinOp (vectorTypeProp c1Props) (vectorTypeProp c2Props) op
  opConst <- inferConstVecBinOp (constProp c1Props) (constProp c2Props) op
  opCard <- inferCardOneBinOp (card1Prop c1Props) (card1Prop c2Props) op
  return $ BUProps { emptyProp = opEmpty 
                   , constProp = opConst
                   , card1Prop = opCard
                   , vectorTypeProp = opType }
  
inferTerOp :: AlgNode
              -> TerOp
              -> BottomUpProps
              -> BottomUpProps
              -> BottomUpProps
              -> Either String BottomUpProps
inferTerOp _ op c1Props c2Props c3Props = do
  opEmpty <- inferEmptyTerOp (emptyProp c1Props) (emptyProp c2Props) (emptyProp c3Props) op
  opType <- inferVectorTypeTerOp (vectorTypeProp c1Props) (vectorTypeProp c1Props) (vectorTypeProp c1Props) op
  opConst <- inferConstVecTerOp (constProp c1Props) (constProp c2Props) (constProp c3Props) op
  opCard <- inferCardOneTerOp (card1Prop c1Props) (card1Prop c2Props) (card1Prop c3Props) op
  return $ BUProps { emptyProp = opEmpty 
                   , constProp = opConst
                   , card1Prop = opCard
                   , vectorTypeProp = opType }
  
-- | Infer bottom-up properties: visit nodes in reverse topological ordering.
inferBottomUpProperties :: [AlgNode] -> AlgebraDag VL -> NodeMap BottomUpProps
inferBottomUpProperties topOrderedNodes d = foldr (inferWorker $ nodeMap d) M.empty topOrderedNodes 

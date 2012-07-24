module Optimizer.VL.Properties.BottomUp where

import Text.PrettyPrint

import qualified Data.Map as M

import Database.Algebra.Dag
import Database.Algebra.Dag.Common
import Database.Algebra.VL.Data

import Optimizer.VL.Properties.Types
import Optimizer.VL.Properties.Empty
import Optimizer.VL.Properties.Card
import Optimizer.VL.Properties.VectorSchema

-- | Perform a map lookup and fail with the given error string if the key
-- is not present
lookupUnsafe :: (Ord k, Show k, Show a) => M.Map k a -> String -> k -> a
lookupUnsafe m s u = 
    case M.lookup u m of
        Just p -> p
        Nothing -> error $ s ++ " " ++ (show u) ++ " in " ++ (show m)

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
  opCardOne <- Right $ inferCardOneNullOp op
  opSchema <- inferSchemaNullOp op
  return $ BUProps { emptyProp = opEmpty 
                   , cardOneProp = opCardOne
                   , vectorSchemaProp = opSchema }
    
inferUnOp :: AlgNode -> UnOp -> BottomUpProps -> Either String BottomUpProps
inferUnOp _ op cProps = do
  opEmpty <- inferEmptyUnOp (emptyProp cProps) op
  opCardOne <- Right $ inferCardOneUnOp (cardOneProp cProps) op
  opSchema <- inferSchemaUnOp (vectorSchemaProp cProps) op
  return $ BUProps { emptyProp = opEmpty 
                   , cardOneProp = opCardOne 
                   , vectorSchemaProp = opSchema }
  
inferBinOp :: AlgNode -> BinOp -> BottomUpProps -> BottomUpProps -> Either String BottomUpProps
inferBinOp _ op c1Props c2Props = do
  opEmpty <- inferEmptyBinOp (emptyProp c1Props) (emptyProp c2Props) op
  opCardOne <- Right $ inferCardOneBinOp (cardOneProp c1Props) (cardOneProp c2Props) op
  opSchema <- inferSchemaBinOp (vectorSchemaProp c1Props) (vectorSchemaProp c2Props) op
  return $ BUProps { emptyProp = opEmpty 
                   , cardOneProp = opCardOne 
                   , vectorSchemaProp = opSchema }
  
inferTerOp :: AlgNode
              -> TerOp
              -> BottomUpProps
              -> BottomUpProps
              -> BottomUpProps
              -> Either String BottomUpProps
inferTerOp _ op c1Props c2Props c3Props = do
  opEmpty <- inferEmptyTerOp (emptyProp c1Props) (emptyProp c2Props) (emptyProp c3Props) op
  opCardOne <- Right $ inferCardOneTerOp (cardOneProp c1Props) (cardOneProp c2Props) (cardOneProp c3Props) op
  opSchema <- inferSchemaTerOp (vectorSchemaProp c1Props) (vectorSchemaProp c1Props) (vectorSchemaProp c1Props) op
  return $ BUProps { emptyProp = opEmpty 
                   , cardOneProp = opCardOne 
                   , vectorSchemaProp = opSchema }
  
-- | Infer bottom-up properties: visit nodes in reverse topological ordering.
inferBottomUpProperties :: [AlgNode] -> AlgebraDag VL -> NodeMap BottomUpProps
inferBottomUpProperties topOrderedNodes d = foldr (inferWorker $ nodeMap d) M.empty topOrderedNodes 

-- | Rendering function for the bottom-up properties container.
renderBottomUpProps :: BottomUpProps -> Doc
renderBottomUpProps props = text "empty: " <> (text $ show $ emptyProp props)
                            

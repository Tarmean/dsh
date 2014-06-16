{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Optimizer.VL.Rewrite.Aggregation(groupingToAggregation) where

import           Control.Applicative
import           Control.Monad
import qualified Data.List.NonEmpty as N

import           Database.Algebra.Dag.Common

import           Database.DSH.VL.Lang
import           Database.DSH.Optimizer.Common.Rewrite
import           Database.DSH.Optimizer.VL.Properties.Types
import           Database.DSH.Optimizer.VL.Rewrite.Common

aggregationRules :: VLRuleSet ()
aggregationRules = [ inlineAggrSProject
                   , inlineAggrProject
                   , inlineAggrNonEmptyProject
                   , flatGrouping
                   , simpleGrouping
                   , simpleGroupingProject
                   , mergeNonEmptyAggrs
                   ]

aggregationRulesBottomUp :: VLRuleSet BottomUpProps
aggregationRulesBottomUp = [ nonEmptyAggr
                           , nonEmptyAggrS
                           ]

groupingToAggregation :: VLRewrite Bool
groupingToAggregation = iteratively $ sequenceRewrites [ applyToAll inferBottomUp aggregationRulesBottomUp
                                                       , applyToAll noProps aggregationRules
                                                       ]

appendNE :: N.NonEmpty a -> N.NonEmpty a -> N.NonEmpty a
appendNE (x N.:| xs) (y N.:| ys) = x N.:| (xs ++ (y : ys))

mergeNonEmptyAggrs :: VLRule ()
mergeNonEmptyAggrs q =
  $(pattern 'q "((qo1) AggrNonEmptyS afuns1 (qi1)) Zip ((qo2) AggrNonEmptyS afuns2 (qi2))"
    [| do
        predicate $ $(v "qo1") == $(v "qo2")
        predicate $ $(v "qi1") == $(v "qi2")

        return $ do
            logRewrite "Aggregation.NonEmpty.Merge" q
            let afuns  = appendNE $(v "afuns1")  $(v "afuns2")
            let aggrOp = BinOp (AggrNonEmptyS afuns) $(v "qo1") $(v "qi1")
            void $ replaceWithNew q aggrOp |])

nonEmptyAggr :: VLRule BottomUpProps
nonEmptyAggr q =
  $(pattern 'q "Aggr aggrFun (q1)"
    [| do
        VProp True <- nonEmptyProp <$> properties $(v "q1")

        return $ do
            logRewrite "Aggregation.NonEmpty.Aggr" q
            let aggrOp = UnOp (AggrNonEmpty ($(v "aggrFun") N.:| [])) $(v "q1")
            void $ replaceWithNew q aggrOp |])

nonEmptyAggrS :: VLRule BottomUpProps
nonEmptyAggrS q =
  $(pattern 'q "(q1) AggrS aggrFun (q2)"
    [| do
        VProp True <- nonEmptyProp <$> properties $(v "q2")

        return $ do
            logRewrite "Aggregation.NonEmpty.AggrS" q
            let aggrOp = BinOp (AggrNonEmptyS ($(v "aggrFun") N.:| [])) $(v "q1") $(v "q2")
            void $ replaceWithNew q aggrOp |])

-- | If an expression operator is applied to the R2 output of GroupBy,
-- push the expression below the GroupBy operator. This rewrite
-- assists in turning combinations of GroupBy and Vec* into a form
-- that is suitable for rewriting into a VecAggr form. Even if this is
-- not possible, the rewrite should not do any harm
pushExprThroughGroupBy :: VLRule BottomUpProps
pushExprThroughGroupBy q = 
  $(pattern 'q "Project projs (qr2=R2 (qg=(qc) GroupBy (qp)))"
    [| do
        [e] <- return $(v "projs")
        case e of
          Column _ -> fail "no match"
          _         -> return ()
        
        -- get vector type of right grouping input to determine the
        -- width of the vector
        VProp (ValueVector w) <- vectorTypeProp <$> properties $(v "qp")
        
        return $ do
          logRewrite "Aggregation.Normalize.PushProject" q
          -- Introduce a new column below the GroupBy operator which contains
          -- the expression result
          let proj = map Column [1 .. w] ++ [e]
          projectNode <- insert $ UnOp (Project proj) $(v "qp")
          
          -- Link the GroupBy operator to the new projection
          groupNode   <- replaceWithNew $(v "qg") $ BinOp GroupBy $(v "qc") projectNode
          r2Node      <- replaceWithNew $(v "qr2") $ UnOp R2 groupNode
          
          -- Replace the CompExpr1L operator with a projection on the new column
          void $ replaceWithNew q $ UnOp (Project [Column $ w + 1]) r2Node |])

-- | Merge a projection into a segmented aggregate operator.
inlineAggrProject :: VLRule ()
inlineAggrProject q =
  $(pattern 'q "Aggr afun (Project proj (qi))"
    [| do
        let env = zip [1..] $(v "proj")
        let afun' = case $(v "afun") of
                        AggrMax e   -> AggrMax $ mergeExpr env e
                        AggrSum t e -> AggrSum t $ mergeExpr env e 
                        AggrMin e   -> AggrMin $ mergeExpr env e
                        AggrAvg e   -> AggrAvg $ mergeExpr env e
                        AggrAny e   -> AggrAny $ mergeExpr env e
                        AggrAll e   -> AggrAll $ mergeExpr env e
                        AggrCount   -> AggrCount

        return $ do
            logRewrite "Aggregation.Normalize.Aggr.Project" q
            void $ replaceWithNew q $ UnOp (Aggr afun') $(v "qi") |])

-- | Merge a projection into a segmented aggregate operator.
inlineAggrSProject :: VLRule ()
inlineAggrSProject q =
  $(pattern 'q "(qo) AggrS afun (Project proj (qi))"
    [| do
        let env = zip [1..] $(v "proj")
        let afun' = case $(v "afun") of
                        AggrMax e   -> AggrMax $ mergeExpr env e
                        AggrSum t e -> AggrSum t $ mergeExpr env e 
                        AggrMin e   -> AggrMin $ mergeExpr env e
                        AggrAvg e   -> AggrAvg $ mergeExpr env e
                        AggrAny e   -> AggrAny $ mergeExpr env e
                        AggrAll e   -> AggrAll $ mergeExpr env e
                        AggrCount   -> AggrCount

        return $ do
            logRewrite "Aggregation.Normalize.AggrS.Project" q
            void $ replaceWithNew q $ BinOp (AggrS afun') $(v "qo") $(v "qi") |])

-- | Merge a projection into a non-empty aggregate operator. We
-- restrict this to only one aggregate function. Therefore, merging of
-- projections must happen before merging of aggregate operators
inlineAggrNonEmptyProject :: VLRule ()
inlineAggrNonEmptyProject q =
  $(pattern 'q "AggrNonEmpty afuns (Project proj (qi))"
    [| do
        afun N.:| [] <- return $(v "afuns")
        let env = zip [1..] $(v "proj")
        let afun' = case afun of
                        AggrMax e   -> AggrMax $ mergeExpr env e
                        AggrSum t e -> AggrSum t $ mergeExpr env e 
                        AggrMin e   -> AggrMin $ mergeExpr env e
                        AggrAvg e   -> AggrAvg $ mergeExpr env e
                        AggrAny e   -> AggrAny $ mergeExpr env e
                        AggrAll e   -> AggrAll $ mergeExpr env e
                        AggrCount   -> AggrCount

        return $ do
            logRewrite "Aggregation.Normalize.AggrNonEmpty.Project" q
            let aggrOp = UnOp (AggrNonEmpty (afun' N.:| [])) $(v "qi")
            void $ replaceWithNew q aggrOp |])

-- | Merge a projection into a non-empty segmented aggregate
-- operator. We restrict this to only one aggregate
-- function. Therefore, merging of projections must happen before
-- merging of aggregate operators
inlineAggrSNonEmptyProject :: VLRule ()
inlineAggrSNonEmptyProject q =
  $(pattern 'q "(qo) AggrNonEmptyS afuns (Project proj (qi))"
    [| do
        afun N.:| [] <- return $(v "afuns")
        let env = zip [1..] $(v "proj")
        let afun' = case afun of
                        AggrMax e   -> AggrMax $ mergeExpr env e
                        AggrSum t e -> AggrSum t $ mergeExpr env e 
                        AggrMin e   -> AggrMin $ mergeExpr env e
                        AggrAvg e   -> AggrAvg $ mergeExpr env e
                        AggrAny e   -> AggrAny $ mergeExpr env e
                        AggrAll e   -> AggrAll $ mergeExpr env e
                        AggrCount   -> AggrCount

        return $ do
            logRewrite "Aggregation.Normalize.AggrNonEmptyS.Project" q
            let aggrOp = BinOp (AggrNonEmptyS (afun' N.:| [])) $(v "qo") $(v "qi")
            void $ replaceWithNew q aggrOp |])

          
-- | Check if we have an operator combination which is eligible for moving to a
-- GroupAggr operator.
matchAggr :: AlgNode -> VLMatch () (AggrFun, AlgNode)
matchAggr q = do
  BinOp (AggrS aggrFun) _ _ <- getOperator q
  return (aggrFun, q)
  
-- If grouping is performed by simple scalar expressions, we can
-- employ a simpler operator.
simpleGrouping :: VLRule ()
simpleGrouping q =
  $(pattern 'q "(Project projs (q1)) GroupBy (q2)"
    [| do
        predicate $ $(v "q1") == $(v "q2")

        return $ do
          logRewrite "Aggregation.Grouping.ScalarS" q
          void $ replaceWithNew q $ UnOp (GroupScalarS $(v "projs")) $(v "q1") |])

-- If grouping is performed by simple scalar expressions, we can
-- employ a simpler operator. This pattern arises when the grouping
-- input projection (left) is merged with the common origin of left
-- and right groupby input.
simpleGroupingProject :: VLRule ()
simpleGroupingProject q =
  $(pattern 'q "R2 (qg=(Project projs1 (q1)) GroupBy (Project projs2 (q2)))"
    [| do
        predicate $ $(v "q1") == $(v "q2")

        return $ do
          logRewrite "Aggregation.Grouping.ScalarS.Project" q

          -- Add the grouping columns to the group input projection
          let projs = $(v "projs2") ++ $(v "projs1")
          projectNode <- insert $ UnOp (Project projs) $(v "q1")

          let groupExprs = [ Column $ i + length $(v "projs2") 
                           | i <- [1 .. length $(v "projs1")]
                           ]

          -- group by the columns that have been added to the input
          -- projection.
          groupNode <- insert $ UnOp (GroupScalarS groupExprs) projectNode

          -- Remove the additional grouping columns from the inner vector
          r2Node <- insert $ UnOp R2 groupNode
          let origSchemaProj = map Column [1 .. length $(v "projs2")]
          topProjectNode <- insert $ UnOp (Project origSchemaProj) r2Node
          replace q topProjectNode

          -- Re-wire R1 and R3 parents of the group operator
          replace $(v "qg") groupNode |])
          
-- We rewrite a combination of GroupBy and aggregation operators into a single
-- VecAggr operator if the following conditions hold: 
--
-- 1. The R2 output of GroupBy is only consumed by aggregation operators (MaxL, 
--    MinL, VecSumL, LengthSeg)
-- 2. The grouping criteria is a simple column projection from the input vector
flatGrouping :: VLRule ()
flatGrouping q =
  $(pattern 'q "R2 (qg=GroupScalarS groupExprs (q1))"
    [| do
        -- We ensure that all parents of the groupBy are operators which we can
        -- turn into aggregate functions
        groupByParents <- getParents q
        funs@(f : fs)  <- mapM matchAggr groupByParents
        
        return $ do
          logRewrite "Aggregation.Grouping.Aggr" q
          -- The output format of the new VecAggr operator is 
          -- [p1, ..., pn, a1, ..., am] where p1, ..., pn are the 
          -- grouping columns and a1, ..., am are the aggregates 
          -- themselves.
        
          -- We obviously assume that the grouping columns are still present in
          -- the right input of GroupBy at the same position. In combination
          -- with rewrite pushExprThroughGroupBy, this is true since we only
          -- add columns at the end.
          aggrNode <- insert $ UnOp (GroupAggr $(v "groupExprs") (fst f N.:| map fst fs)) $(v "q1")

          -- For every aggregate function, generate a projection which only
          -- leaves the aggregate column. Function receives the node of the
          -- original aggregate operator and the column in which the respective 
          -- aggregation result resides.
          let insertAggrProject :: AlgNode -> DBCol -> VLRewrite ()
              insertAggrProject oldAggrNode aggrCol = 
                void $ replaceWithNew oldAggrNode $ UnOp (Project [Column aggrCol]) aggrNode

          let gw = length $(v "groupExprs")

          zipWithM_ insertAggrProject (map snd funs) (map (+ gw) [1 .. length funs])
          
          -- If the R1 output (that is, the vector which contains the grouping
          -- columns and desribes the group shape) of GroupBy is referenced, we
          -- replace it with a projection on the new VecAggr node.
          r1s <- lookupR1Parents $(v "qg")
          if length r1s > 0
            then do
              let projs = map Column [1 .. length $(v "groupExprs")]
              r1ProjectNode <- insert $ UnOp (Project projs) aggrNode
              mapM_ (\r1 -> replace r1 r1ProjectNode) r1s
            else return () |])

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedLists #-}

module Database.DSH.SL.Opt.Rewrite.Redundant (removeRedundancy) where

import           Control.Monad

import           Database.Algebra.Dag.Common

import           Database.DSH.Common.Lang
import           Database.DSH.Common.Nat
import           Database.DSH.Common.Opt
import           Database.DSH.Common.VectorLang

import           Database.DSH.SL.Lang
import           Database.DSH.SL.Opt.Properties.Types
-- import           Database.DSH.SL.Opt.Properties.VectorType
import           Database.DSH.SL.Opt.Rewrite.Aggregation
import           Database.DSH.SL.Opt.Rewrite.Common
import           Database.DSH.SL.Opt.Rewrite.Projections
-- import           Database.DSH.SL.Opt.Rewrite.Window

{-# ANN module "HLint: ignore Reduce duplication" #-}

removeRedundancy :: SLRewrite TExpr TExpr Bool
removeRedundancy =
    iteratively $ sequenceRewrites [ cleanup
                                   , applyToAll noProps redundantRules
                                   , applyToAll inferBottomUp redundantRulesBottomUp
                                   , applyToAll inferProperties redundantRulesAllProps
                                   , groupingToAggregation
                                   ]

cleanup :: SLRewrite TExpr TExpr Bool
cleanup = iteratively $ sequenceRewrites [ optExpressions ]

redundantRules :: SLRuleSet TExpr TExpr ()
redundantRules = [ scalarConditional
                 , pushFoldAppMap
                 , pushFoldAppKey
                 , pushUnboxSngSelect
                 , pushUnboxSngAlign
                 , pushUnboxSngReplicateScalar
                 , pullNumberReplicateNest
                 , sameInputAlign
                 , sameInputZip
                 -- , sameInputZipProject
                 -- , sameInputZipProjectLeft
                 -- , sameInputZipProjectRight
                 , zipProjectLeft
                 , zipProjectRight
                 , distLiftStacked
                 -- , distLiftSelect
                 , alignedDistLeft
                 , alignedDistRight
                 -- , zipConstLeft
                 -- , zipConstRight
                 -- , alignConstLeft
                 -- , alignConstRight
                 , zipZipLeft
                 , alignWinLeft
                 , alignWinRight
                 , zipWinLeft
                 , zipWinRight
                 -- , zipWinRight2
                 , alignWinRightPush
                 , alignUnboxSngRight
                 , alignUnboxSngLeft
                 , alignUnboxDefaultRight
                 , alignUnboxDefaultLeft
                 , alignGroupJoinLeft
                 , alignGroupJoinRight
                 -- , runningAggWinBounded
                 -- , runningAggWinUnbounded
                 -- , runningAggWinUnboundedGroupJoin
                 -- , inlineWinAggrProject
                 -- , constDist
                 , selectCartProd
                 , pushUnboxSngThetaJoinRight
                 , pullNumberAlignLeft
                 , pullNumberAlignRight
                 , stackedAlign1
                 , stackedAlign2
                 , stackedAlign3
                 , stackedAlign4
                 , stackedNumber
                 ]


redundantRulesBottomUp :: SLRuleSet TExpr TExpr BottomUpProps
redundantRulesBottomUp = [ distLiftNestJoin
                         , nestJoinChain
                         , alignCartProdRight
                         ]

redundantRulesAllProps :: SLRuleSet TExpr TExpr Properties
redundantRulesAllProps = [ -- unreferencedReplicateNest
                         -- , notReqNumber
                         -- , unboxNumber
                         ]

--------------------------------------------------------------------------------
--

-- unwrapConstVal :: ConstPayload -> SLMatch p ScalarVal
-- unwrapConstVal (ConstPL val) = return val
-- unwrapConstVal  NonConstPL   = fail "not a constant"

-- | If the left input of a dist operator is constant, a normal projection
-- can be used because the Dist* operators keeps the shape of the
-- right input.
-- constDist :: SLRule TExpr TExpr BottomUpProps
-- constDist q =
--   $(dagPatMatch 'q "R1 ((q1) [ReplicateNest | ReplicateScalar] (q2))"
--     [| do
--          VProp (ConstVec constCols) <- constProp <$> properties $(v "q1")
--          VProp (VTDataVec w)        <- vectorTypeProp <$> properties $(v "q2")
--          constVals                  <- mapM unwrapConstVal constCols

--          return $ do
--               logRewrite "Redundant.Const.ReplicateNest" q
--               let proj = map Constant constVals ++ map Column [1..w]
--               void $ replaceWithNew q $ UnOp (Project proj) $(v "q2") |])

-- | If a vector is distributed over an inner vector in a segmented
-- way, check if the vector's columns are actually referenced/required
-- downstream. If not, we can remove the ReplicateNest altogether, as the
-- shape of the inner vector is not changed by ReplicateNest.
-- unreferencedReplicateNest :: SLRule TExpr TExpr Properties
-- unreferencedReplicateNest q =
--   $(dagPatMatch 'q  "R1 ((q1) ReplicateNest (q2))"
--     [| do
--         VProp (Just reqCols) <- reqColumnsProp . td <$> properties q
--         VProp (VTDataVec w1) <- vectorTypeProp . bu <$> properties $(v "q1")
--         VProp (VTDataVec w2) <- vectorTypeProp . bu <$> properties $(v "q2")

--         -- Check that only columns from the right input are required
--         predicate $ all (> w1) reqCols

--         return $ do
--           logRewrite "Redundant.Unreferenced.ReplicateNest" q

--           -- FIXME HACKHACKHACK
--           let padProj = [ Constant $ IntV 0xdeadbeef | _ <- [1..w1] ]
--                         ++
--                         [ Column i | i <- [1..w2] ]

--           void $ replaceWithNew q $ UnOp (Project padProj) $(v "q2") |])

-- | Remove a ReplicateNest if the outer vector is aligned with a
-- NestJoin that uses the same outer vector.
-- FIXME try to generalize to NestJoinS
distLiftNestJoin :: SLRule TExpr TExpr BottomUpProps
distLiftNestJoin q =
  $(dagPatMatch 'q "R1 ((qo) ReplicateNest (R1 ((qo1) NestJoin p (qi))))"
    [| do
        predicate $ $(v "qo") == $(v "qo1")

        -- Only allow the rewrite if both product inputs are flat (i.e. unit
        -- segment). This is equivalent to the old flat NestProduct rewrite.
        VProp UnitSegP <- segProp <$> properties $(v "qo1")
        VProp UnitSegP <- segProp <$> properties $(v "qi")

        return $ do
            logRewrite "Redundant.ReplicateNest.NestJoin" q
            -- Preserve the original schema
            let e = TMkTuple [ TTupElem First TInput
                             , TInput
                             ]
            prodNode <- insert $ BinOp (NestJoin $(v "p")) $(v "qo") $(v "qi")
            r1Node   <- insert $ UnOp R1 prodNode
            void $ replaceWithNew q $ UnOp (Project e) r1Node |])

-- If the same outer vector is propagated twice to an inner vector, one
-- ReplicateNest can be removed. Reasoning: ReplicateNest does not change the
-- shape of the inner vector.
distLiftStacked :: SLRule TExpr TExpr ()
distLiftStacked q =
  $(dagPatMatch 'q "R1 ((q1) ReplicateNest (r1=R1 ((q11) ReplicateNest (_))))"
     [| do
         predicate $ $(v "q1") == $(v "q11")

         return $ do
             logRewrite "Redundant.ReplicateNest.Stacked" q
             let e = TMkTuple [ TTupElem First TInput
                              , TMkTuple [ TTupElem First TInput
                                         , TTupElem (Next First) TInput
                                         ]
                              ]
             void $ replaceWithNew q $ UnOp (Project e) $(v "r1") |])

-- | Pull a selection through a ReplicateNest. The reasoning for
-- correctness is simple: It does not matter wether an element of an
-- inner segment is removed before or after ReplicateNest (on relational
-- level, ReplicateNest maps to join which commutes with selection). The
-- "use case" for this rewrite is not well thought-through yet: We
-- want to push down ReplicateNest to eliminate it or merge it with other
-- operators (e.g. ReplicateNest.Stacked). The usual wisdom would suggest
-- to push selections down, though.
--
-- FIXME this rewrite is on rather shaky ground semantically.
-- distLiftSelect :: SLRule TExpr TExpr BottomUpProps
-- distLiftSelect q =
--   $(dagPatMatch 'q "R1 ((q1) ReplicateNest (R1 (Select p (q2))))"
--      [| do
--          w1 <- vectorWidth . vectorTypeProp <$> properties $(v "q1")
--          return $ do
--              logRewrite "Redundant.ReplicateNest.Select" q
--              let p' = shiftExprCols w1 $(v "p")
--              distNode <- insert $ BinOp ReplicateNest $(v "q1") $(v "q2")
--              distR1   <- insert $ UnOp R1 distNode
--              selNode  <- insert $ UnOp (Select p') distR1
--              void $ replaceWithNew q $ UnOp R1 selNode |])

-- | When a ReplicateNest result is aligned with the right (inner) ReplicateNest
-- input, we can eliminate the Align. Reasoning: ReplicateNest does not
-- change the shape of the vector, only adds columns from its right
-- input.
alignedDistRight :: SLRule TExpr TExpr ()
alignedDistRight q =
  $(dagPatMatch 'q "(q21) Align (qr1=R1 ((_) [ReplicateNest | ReplicateScalar] (q22)))"
    [| do
        predicate $ $(v "q21") == $(v "q22")

        return $ do
            logRewrite "Redundant.Dist.Align.Right" q
            let e = TMkTuple [ TTupElem (Next First) TInput
                             , TInput
                             ]
            void $ replaceWithNew q $ UnOp (Project e) $(v "qr1") |])

-- | When a ReplicateNest result is aligned with the right (inner) ReplicateNest
-- input, we can eliminate the Align. Reasoning: ReplicateNest does not
-- change the shape of the vector, only adds columns from its right
-- input.
alignedDistLeft :: SLRule TExpr TExpr ()
alignedDistLeft q =
  $(dagPatMatch 'q "(qr1=R1 ((_) [ReplicateNest | ReplicateScalar] (q21))) Align (q22)"
    [| do
        predicate $ $(v "q21") == $(v "q22")

        return $ do
            logRewrite "Redundant.Dist.Align.Left" q
            let e = TMkTuple [ TInput
                             , TTupElem (Next First) TInput
                             ]
            void $ replaceWithNew q $ UnOp (Project e) $(v "qr1") |])

--------------------------------------------------------------------------------
-- Zip and Align rewrites.

-- Note that the rewrites valid for Zip are a subset of the rewrites
-- valid for Align. In the case of Align, we statically know that both
-- inputs have the same length and can be positionally aligned without
-- discarding elements.

-- | Replace an Align operator with a projection if both inputs are the
-- same.
sameInputAlign :: SLRule TExpr TExpr ()
sameInputAlign q =
  $(dagPatMatch 'q "(q1) Align (q2)"
    [| do
        predicate $ $(v "q1") == $(v "q2")

        return $ do
          logRewrite "Redundant.Align.Self" q
          let e = TMkTuple [TInput, TInput]
          void $ replaceWithNew q $ UnOp (Project e) $(v "q1") |])

-- | Replace an Align operator with a projection if both inputs are the
-- same.
sameInputZip :: SLRule TExpr TExpr ()
sameInputZip q =
  $(dagPatMatch 'q "R1 ((q1) Zip (q2))"
    [| do
        predicate $ $(v "q1") == $(v "q2")

        return $ do
          logRewrite "Redundant.Zip.Self" q
          let e = TMkTuple [TInput, TInput]
          void $ replaceWithNew q $ UnOp (Project e) $(v "q1") |])

-- sameInputZipProject :: SLRule TExpr TExpr BottomUpProps
-- sameInputZipProject q =
--   $(dagPatMatch 'q "(Project ps1 (q1)) [Zip | Align] (Project ps2 (q2))"
--     [| do
--         predicate $ $(v "q1") == $(v "q2")

--         return $ do
--           logRewrite "Redundant.Zip/Align.Self.Project" q
--           void $ replaceWithNew q $ UnOp (Project ($(v "ps1") ++ $(v "ps2"))) $(v "q1") |])

-- sameInputZipProjectLeft :: SLRule TExpr TExpr BottomUpProps
-- sameInputZipProjectLeft q =
--   $(dagPatMatch 'q "(Project ps1 (q1)) [Zip | Align] (q2)"
--     [| do
--         predicate $ $(v "q1") == $(v "q2")
--         w1 <- liftM (vectorWidth . vectorTypeProp) $ properties $(v "q1")

--         return $ do
--           logRewrite "Redundant.Zip/Align.Self.Project.Left" q
--           let proj = $(v "ps1") ++ (map Column [1..w1])
--           void $ replaceWithNew q $ UnOp (Project proj) $(v "q1") |])

-- sameInputZipProjectRight :: SLRule TExpr TExpr BottomUpProps
-- sameInputZipProjectRight q =
--   $(dagPatMatch 'q "(q1) [Zip | Align] (Project ps2 (q2))"
--     [| do
--         predicate $ $(v "q1") == $(v "q2")
--         w <- liftM (vectorWidth . vectorTypeProp) $ properties $(v "q1")

--         return $ do
--           logRewrite "Redundant.Zip/Align.Self.Project.Right" q
--           let proj = (map Column [1 .. w]) ++ $(v "ps2")
--           void $ replaceWithNew q $ UnOp (Project proj) $(v "q1") |])

zipProjectLeft :: SLRule TExpr TExpr ()
zipProjectLeft q =
  $(dagPatMatch 'q "R1 ((Project e (q1)) Zip (q2))"
    [| do
        return $ do
          logRewrite "Redundant.Zip.Project.Left" q
          -- Take the projection expressions from the left and the
          -- shifted columns from the right.
          let e' = appExprFst $(v "e")
          zipNode <- insert $ BinOp Zip $(v "q1") $(v "q2")
          r1Node  <- insert $ UnOp R1 zipNode
          void $ replaceWithNew q $ UnOp (Project e') r1Node |])

zipProjectRight :: SLRule TExpr TExpr ()
zipProjectRight q =
  $(dagPatMatch 'q "R1 ((q1) Zip (Project e (q2)))"
    [| do
        return $ do
          logRewrite "Redundant.Zip.Project.Right" q
          -- Take the columns from the left and the expressions from
          -- the right projection. Since expressions are applied after
          -- the zip, their column references have to be shifted.
          let e' = appExprSnd $(v "e")
          zipNode <- insert $ BinOp Zip $(v "q1") $(v "q2")
          r1Node  <- insert $ UnOp R1 zipNode
          void $ replaceWithNew q $ UnOp (Project e') r1Node |])

-- fromConst :: Monad m => ConstPayload -> m ScalarVal
-- fromConst (ConstPL val) = return val
-- fromConst NonConstPL    = fail "not a constant"

-- -- | This rewrite is valid because we statically know that both
-- -- vectors have the same length.
-- alignConstLeft :: SLRule TExpr TExpr BottomUpProps
-- alignConstLeft q =
--   $(dagPatMatch 'q "(q1) Align (q2)"
--     [| do
--         VProp (ConstVec ps) <- constProp <$> properties $(v "q1")
--         w2                  <- vectorWidth . vectorTypeProp <$> properties $(v "q2")
--         vals                <- mapM fromConst ps

--         return $ do
--             logRewrite "Redundant.Align.Constant.Left" q
--             let proj = map Constant vals ++ map Column [1..w2]
--             void $ replaceWithNew q $ UnOp (Project proj) $(v "q2") |])

-- alignConstRight :: SLRule TExpr TExpr BottomUpProps
-- alignConstRight q =
--   $(dagPatMatch 'q "(q1) Align (q2)"
--     [| do
--         w1                  <- vectorWidth . vectorTypeProp <$> properties $(v "q1")
--         VProp (ConstVec ps) <- constProp <$> properties $(v "q2")
--         vals                <- mapM fromConst ps

--         return $ do
--             logRewrite "Redundant.Align.Constant.Right" q
--             let proj = map Column [1..w1] ++ map Constant vals
--             void $ replaceWithNew q $ UnOp (Project proj) $(v "q1") |])

-- -- | In contrast to the 'Align' version ('alignConstLeft') this rewrite is only
-- -- valid if we can statically determine that both input vectors have the same
-- -- length. If the constant vector was shorter, overhanging elements from the
-- -- non-constant vector would need to be discarded. In general, we can only
-- -- determine equal length for the special case of length one.
-- --
-- -- Since we use Zip here, we have to ensure that the constant is in the same
-- -- segment as the entry from the non-constant tuple. At the moment, we can
-- -- guarantee this only for unit-segment vectors.
-- zipConstLeft :: SLRule TExpr TExpr BottomUpProps
-- zipConstLeft q =
--   $(dagPatMatch 'q "R1 ((q1) Zip (q2))"
--     [| do

--         prop1               <- properties $(v "q1")
--         VProp card1         <- return $ card1Prop prop1
--         VProp (ConstVec ps) <- return $ constProp prop1
--         VProp UnitSegP      <- return $ segProp prop1

--         prop2               <- properties $(v "q2")
--         VProp card2         <- return $ card1Prop prop2
--         w2                  <- vectorWidth . vectorTypeProp <$> properties $(v "q2")
--         VProp UnitSegP      <- return $ segProp prop2

--         vals                <- mapM fromConst ps
--         predicate $ card1 && card2

--         return $ do
--             logRewrite "Redundant.Zip.Constant.Left" q
--             let proj = map Constant vals ++ map Column [1..w2]
--             void $ replaceWithNew q $ UnOp (Project proj) $(v "q2") |])

-- zipConstRight :: SLRule TExpr TExpr BottomUpProps
-- zipConstRight q =
--   $(dagPatMatch 'q "R1 ((q1) Zip (q2))"
--     [| do
--         prop1               <- properties $(v "q1")
--         VProp card1         <- return $ card1Prop prop1
--         w1                  <- vectorWidth . vectorTypeProp <$> properties $(v "q1")
--         VProp UnitSegP      <- return $ segProp prop1

--         prop2               <- properties $(v "q2")
--         VProp card2         <- return $ card1Prop prop2
--         VProp (ConstVec ps) <- return $ constProp prop2
--         VProp UnitSegP      <- return $ segProp prop2


--         vals                  <- mapM fromConst ps
--         predicate $ card1 && card2

--         return $ do
--             logRewrite "Redundant.Zip.Constant.Right" q
--             let proj = map Column [1..w1] ++ map Constant vals
--             void $ replaceWithNew q $ UnOp (Project proj) $(v "q1") |])

zipZipLeft :: SLRule TExpr TExpr ()
zipZipLeft q =
  $(dagPatMatch 'q "(q1) Zip (qz=(q11) [Zip | Align] (_))"
     [| do
         predicate $ $(v "q1") == $(v "q11")

         return $ do
             logRewrite "Redundant.Zip/Align.Zip.Left" q
             let e = TMkTuple [ TTupElem First TInput
                              , TInput
                              ]
             void $ replaceWithNew q $ UnOp (Project e) $(v "qz") |])

alignWinRight :: SLRule TExpr TExpr ()
alignWinRight q =
  $(dagPatMatch 'q "(q1) Align (qw=WinFun _ (q2))"
     [| do
         predicate $ $(v "q1") == $(v "q2")

         return $ do
             logRewrite "Redundant.Align.Self.Win.Right" q
             -- We get all columns from the left input. The WinAggr
             -- operator produces the input column followed by the
             -- window function result.
             let e = TMkTuple [ TTupElem First TInput
                              , TInput
                              ]
             void $ replaceWithNew q $ UnOp (Project e) $(v "qw") |])

zipWinRight :: SLRule TExpr TExpr ()
zipWinRight q =
  $(dagPatMatch 'q "R1 ((q1) Zip (qw=WinFun _ (q2)))"
     [| do
         predicate $ $(v "q1") == $(v "q2")

         return $ do
             logRewrite "Redundant.Zip.Self.Win.Right" q
             -- We get all columns from the left input. The WinAggr
             -- operator produces the input column followed the window
             -- function result.
             let e = TMkTuple [ TTupElem First TInput
                              , TInput
                              ]
             void $ replaceWithNew q $ UnOp (Project e) $(v "qw") |])

-- | Remove a Zip operator when the right input consists of two window
-- operators.
--
-- FIXME this should be solved properly for the general case.
-- zipWinRight2 :: SLRule TExpr TExpr BottomUpProps
-- zipWinRight2 q =
--   $(dagPatMatch 'q "R1 ((q1) Zip (qw=WinFun _ (WinFun _ (q2))))"
--      [| do
--          predicate $ $(v "q1") == $(v "q2")

--          w <- vectorWidth . vectorTypeProp <$> properties $(v "q1")

--          return $ do
--              logRewrite "Redundant.Zip.Self.Win.Right.Double" q
--              -- We get all columns from the left input. The WinAggr
--              -- operator produces the input column followed the window
--              -- function result.
--              let proj = map Column $ [1 .. w] ++ [1 .. w] ++ [w+1, w+2]
--              -- logGeneral ("zipWinRight " ++ show proj)
--              void $ replaceWithNew q $ UnOp (Project proj) $(v "qw") |])

alignWinLeft :: SLRule TExpr TExpr ()
alignWinLeft q =
  $(dagPatMatch 'q "(qw=WinFun _ (q1)) Align (q2)"
     [| do
         predicate $ $(v "q1") == $(v "q2")

         return $ do
             logRewrite "Redundant.Align.Self.Win.Left" q
             -- We get all input columns plus the window function
             -- output from the left. From the right we get all input
             -- columns.
             let e = TMkTuple [ TInput
                              , TTupElem First TInput
                              ]
             void $ replaceWithNew q $ UnOp (Project e) $(v "qw") |])

-- | If the output of a window operator is zipped with its own input, we can
-- remove the Zip operator.
zipWinLeft :: SLRule TExpr TExpr ()
zipWinLeft q =
  $(dagPatMatch 'q "R1 ((qw=WinFun _ (q1)) Zip (q2))"
     [| do
         predicate $ $(v "q1") == $(v "q2")

         return $ do
             logRewrite "Redundant.Zip.Self.Win.Left" q
             -- We get all input columns plus the window function
             -- output from the left. From the right we get all input
             -- columns.
             let e = TMkTuple [ TInput
                              , TTupElem First TInput
                              ]
             void $ replaceWithNew q $ UnOp (Project e) $(v "qw") |])

isPrecedingFrameSpec :: FrameSpec -> Bool
isPrecedingFrameSpec fs =
    case fs of
        FAllPreceding -> True
        FNPreceding _ -> True

alignWinRightPush :: SLRule TExpr TExpr ()
alignWinRightPush q =
  $(dagPatMatch 'q "(q1) Align (WinFun args (q2))"
    [| do
        let (winFun, frameSpec) = $(v "args")
        predicate $ isPrecedingFrameSpec frameSpec

        return $ do
            logRewrite "Redundant.Align.Win.Right" q
            zipNode <- insert $ BinOp Align $(v "q1") $(v "q2")
            let winFun' = (partialEval . appExprSnd) <$> winFun
                args'   = (winFun', frameSpec)
            void $ replaceWithNew q $ UnOp (WinFun args') zipNode |])

alignGroupJoinRight :: SLRule TExpr TExpr ()
alignGroupJoinRight q =
  $(dagPatMatch 'q "(qo) Align (gj=(qo1) GroupJoin _ (_))"
    [| do
        predicate $ $(v "qo") == $(v "qo1")
        return $ do
            logRewrite "Redundant.Align.GroupJoin.Right" q
            -- In the result, replicate the columns from the outer
            -- vector to keep the schema intact.
            let e = TMkTuple [ TTupElem First TInput
                             , TInput
                             ]
            void $ replaceWithNew q $ UnOp (Project e) $(v "gj") |])

alignGroupJoinLeft :: SLRule TExpr TExpr ()
alignGroupJoinLeft q =
  $(dagPatMatch 'q "(gj=(qo1) GroupJoin _ (_)) Align (qo)"
    [| do
        predicate $ $(v "qo") == $(v "qo1")
        return $ do
            logRewrite "Redundant.Align.GroupJoin.Left" q
            -- In the result, replicate the columns from the outer
            -- vector to keep the schema intact.
            let e = TMkTuple [ TInput
                             , TTupElem First TInput
                             ]
            void $ replaceWithNew q $ UnOp (Project e) $(v "gj") |])

-- | If the right (outer) input of Unbox is a Number operator and the
-- number output is not required, eliminate it from the outer
-- input. This is correct because Number does not change the vertical
-- shape of the vector.
--
-- The motivation is to eliminate zip operators that align with the
-- unboxed block. By removing Number from the Unbox input, we hope to
-- achieve that the outer input is the same one as the zip input so
-- that we can remove the zip.
--
-- For an example, see the bestProfit query (AQuery examples).
--
-- FIXME This could be extended to all operators that do not modify
-- the vertical shape.
-- unboxNumber :: SLRule TExpr TExpr Properties
-- unboxNumber q =
--   $(dagPatMatch 'q "R1 ((Number (qo)) UnboxSng (qi))"
--     [| do
--         VProp (Just reqCols) <- reqColumnsProp . td <$> properties q
--         VProp (VTDataVec wo) <- vectorTypeProp . bu <$> properties $(v "qo")
--         VProp (VTDataVec wi) <- vectorTypeProp . bu <$> properties $(v "qi")
--         predicate $ (wo+1) `notElem` reqCols

--         return $ do
--             logRewrite "Redundant.Unbox.Number" q
--             -- FIXME HACKHACKHACK We have to insert a dummy column in
--             -- place of the number column to avoid destroying column
--             -- indexes.
--             let proj = map Column [1..wo]
--                        ++ [Constant $ IntV 0xdeadbeef]
--                        ++ map Column [wo+1..wi+wo]
--             unboxNode <- insert $ BinOp UnboxSng $(v "qo") $(v "qi")
--             r1Node    <- insert $ UnOp R1 unboxNode
--             void $ replaceWithNew q $ UnOp (Project proj) r1Node |])

-- | If singleton scalar elements in an inner vector (with singleton
-- segments) are unboxed using an outer vector and then aligned with
-- the same outer vector, we can eliminate the align, because the
-- positional alignment is implicitly performed by the UnboxSng
-- operator. We exploit the fact that UnboxSng is only a
-- specialized join which nevertheless produces payload columns from
-- both inputs.
alignUnboxSngRight :: SLRule TExpr TExpr ()
alignUnboxSngRight q =
  $(dagPatMatch 'q "(q11) Align (qu=R1 ((q12) UnboxSng (_)))"
     [| do
         predicate $ $(v "q11") == $(v "q12")
         return $ do
             logRewrite "Redundant.Align.UnboxSng.Right" q

             -- Keep the original schema intact by duplicating columns
             -- from the left input (UnboxSng produces columns from
             -- its left and right inputs).
             let e = TMkTuple [ TTupElem First TInput
                              , TInput
                              ]

             -- Keep only the unboxing operator, together with a
             -- projection that keeps the original output schema
             -- intact.
             void $ replaceWithNew q $ UnOp (Project e) $(v "qu") |])

-- | See Align.UnboxSng.Right
alignUnboxSngLeft :: SLRule TExpr TExpr ()
alignUnboxSngLeft q =
  $(dagPatMatch 'q "(qu=R1 ((q11) UnboxSng (_))) Align (q12)"
     [| do
         predicate $ $(v "q11") == $(v "q12")
         return $ do
             logRewrite "Redundant.Align.UnboxSng.Left" q

             -- Keep the original schema intact by duplicating columns
             -- from the left input (UnboxSng produces columns from
             -- its left and right inputs).
             let e = TMkTuple [ TInput
                              , TTupElem First TInput
                              ]

             -- Keep only the unboxing operator, together with a
             -- projection that keeps the original output schema
             -- intact.
             void $ replaceWithNew q $ UnOp (Project e) $(v "qu") |])

-- | If singleton scalar elements in an inner vector (with singleton
-- segments) are unboxed using an outer vector and then aligned with
-- the same outer vector, we can eliminate the align, because the
-- positional alignment is implicitly performed by the UnboxDefault
-- operator. We exploit the fact that UnboxDefault is only a
-- specialized join which nevertheless produces payload columns from
-- both inputs.
alignUnboxDefaultRight :: SLRule TExpr TExpr ()
alignUnboxDefaultRight q =
  $(dagPatMatch 'q "(q11) Align (qu=(q12) UnboxDefault _ (_))"
     [| do
         predicate $ $(v "q11") == $(v "q12")
         return $ do
             logRewrite "Redundant.Align.UnboxDefault.Right" q

             -- Keep the original schema intact by duplicating columns
             -- from the left input (UnboxDefault produces columns from
             -- its left and right inputs).
             let e = TMkTuple [ TTupElem First TInput
                              , TInput
                              ]

             -- Keep only the unboxing operator, together with a
             -- projection that keeps the original output schema
             -- intact.
             void $ replaceWithNew q $ UnOp (Project e) $(v "qu") |])

-- | See Align.UnboxDefault.Right
alignUnboxDefaultLeft :: SLRule TExpr TExpr ()
alignUnboxDefaultLeft q =
  $(dagPatMatch 'q "(qu=(q11) UnboxDefault _ (_)) Align (q12)"
     [| do
         predicate $ $(v "q11") == $(v "q12")
         return $ do
             logRewrite "Redundant.Align.UnboxDefault.Left" q

             -- Keep the original schema intact by duplicating columns
             -- from the left input (UnboxDefault produces columns from
             -- its left and right inputs).
             let e = TMkTuple [ TInput
                              , TTupElem First TInput
                              ]

             -- Keep only the unboxing operator, together with a
             -- projection that keeps the original output schema
             -- intact.
             void $ replaceWithNew q $ UnOp (Project e) $(v "qu") |])

-- | A CartProduct output is aligned with some other vector. If one of
-- the CartProduct inputs has cardinality one, the other CartProduct
-- input determines the length of the result vector. From the original
-- structure we can derive that 'q11' and the CartProduct result are
-- aligned. Consequentially, 'q11 and 'q12' (the left CartProduct
-- input) must be aligned as well.
alignCartProdRight :: SLRule TExpr TExpr BottomUpProps
alignCartProdRight q =
  $(dagPatMatch 'q "(q11) Align (R1 ((q12) CartProduct (q2)))"
    [| do
        VProp True <- card1Prop <$> properties $(v "q2")
        return $ do
            logRewrite "Redundant.Align.CartProduct.Card1.Right" q
            alignNode <- insert $ BinOp Align $(v "q11") $(v "q12")
            prodNode  <- insert $ BinOp CartProduct alignNode $(v "q2")
            void $ replaceWithNew q $ UnOp R1 prodNode |])

stackedAlign1 :: SLRule TExpr TExpr ()
stackedAlign1 q =
  $(dagPatMatch 'q "(qa=(q1) Align (_)) Align (q12)"
     [| do
           predicate $ $(v "q1") == $(v "q12")
           return $ do
               logRewrite "Redundant.Align.Stacked.Left.1" q
               let proj = tPair TInput TInpFirst
               void $ replaceWithNew q $ UnOp (Project proj) $(v "qa")
      |]
   )

stackedAlign2 :: SLRule TExpr TExpr ()
stackedAlign2 q =
  $(dagPatMatch 'q "(qa=(_) Align (q2)) Align (q22)"
     [| do
           predicate $ $(v "q2") == $(v "q22")
           return $ do
               logRewrite "Redundant.Align.Stacked.Left.2" q
               let proj = tPair TInput TInpSecond
               void $ replaceWithNew q $ UnOp (Project proj) $(v "qa")
      |]
   )

stackedAlign3 :: SLRule TExpr TExpr ()
stackedAlign3 q =
  $(dagPatMatch 'q "(q11) Align (qa=(q1) Align (_))"
     [| do
           predicate $ $(v "q1") == $(v "q11")
           return $ do
               logRewrite "Redundant.Align.Stacked.Right.1" q
               let proj = tPair TInpFirst TInput
               void $ replaceWithNew q $ UnOp (Project proj) $(v "qa")
      |]
   )

stackedAlign4 :: SLRule TExpr TExpr ()
stackedAlign4 q =
  $(dagPatMatch 'q "(q12) Align (qa=(_) Align (q2))"
     [| do
           predicate $ $(v "q2") == $(v "q12")
           return $ do
               logRewrite "Redundant.Align.Stacked.Right.2" q
               let proj = tPair TInpSecond TInput
               void $ replaceWithNew q $ UnOp (Project proj) $(v "qa")
      |]
   )

--------------------------------------------------------------------------------
-- Scalar conditionals

-- | Under a number of conditions, a combination of Combine and Select
-- (Restrict) operators implements a scalar conditional that can be
-- simply mapped to an 'if' expression evaluated on the input vector.
scalarConditional :: SLRule TExpr TExpr ()
scalarConditional q =
  $(dagPatMatch 'q "R1 (Combine (Project predProj (q1)) (Project thenProj (R1 (Select pred2 (q2)))) (Project elseProj (R1 (Select negPred (q3)))))"
    [| do
        -- All branches must work on the same input vector
        predicate $ $(v "q1") == $(v "q2") && $(v "q1") == $(v "q3")

        -- The condition for the boolean vector must be the same as
        -- the selection condition for the then-branch.
        predicate $ $(v "predProj") == $(v "pred2")

        -- The selection condition must be the negated form of the
        -- then-condition.
        predicate $ TUnApp SUBoolNot $(v "predProj") == $(v "negPred")

        return $ do
          logRewrite "Redundant.ScalarConditional" q
          void $ replaceWithNew q $ UnOp (Project (TIf $(v "predProj") $(v "thenProj") $(v "elseProj"))) $(v "q1") |])

------------------------------------------------------------------------------
-- Projection pullup


--------------------------------------------------------------------------------
-- Rewrites that deal with nested structures and propagation vectors.

-- | Turn a right-deep nestjoin tree into a left-deep one.
--
-- A comprehension of the form
-- @
-- [ [ [ e x y z | z <- zs, p2 y z ]
--   | y <- ys
--   , p1 x y
--   ]
-- | x <- xs
-- ]
-- @
--
-- is first rewritten into a right-deep chain of nestjoins: 'xs △ (ys △ zs)'.
-- Bottom-up compilation of this expression to SL (vectorization) results in
-- a rather awkward plan, though: The inner nestjoin is computed independent
-- of values of 'x'. The join result is then re-shaped using the propagation
-- vector from the nestjoin of the outer relations 'xs' and 'ys'. This pattern
-- is problematic for multiple reasons: PropReorder is an expensive operation as
-- it involves re-ordering semantically, leading to a hard-to-eliminate rownum.
-- On the plan level, we do not get a left- or right-deep join tree of thetajoins,
-- but two independent joins between the two pairs of input relations whose results
-- are connected using an additional join (PropReorder). This means that the two
-- base joins will be executed on the full base tables, without being able to profit
-- from a reduced cardinality in one of the join results.
--
-- NestJoin does not exhibit useful algebraic properties, most notably it is neither
-- associate nor commutative. It turns out however that we can turn the pattern
-- described above into a proper left-deep sequence of nestjoins if we consider
-- the flat (vectorized) representation. The output of 'xs △ ys' is nestjoined
-- with the innermost input 'zs'. This gives us exactly the representation of
-- the nested output that we need. Semantically, 'zs' is not joined with all
-- tuples in 'ys', but only with those that survive the (outer) join with 'xs'.
-- As usual, a proper join tree should give the engine the freedom to re-arrange
-- the joins and drive them in a pipelined manner.
-- FIXME Generalize to NestJoinS
nestJoinChain :: SLRule TExpr TExpr BottomUpProps
nestJoinChain q =
  $(dagPatMatch 'q "R1 ((R3 (lj=(xs) NestJoin _ (ys))) AppRep (R1 ((ys1) NestJoin p (zs))))"
   [| do
       predicate $ $(v "ys") == $(v "ys1")

       -- Only allow the rewrite if all join inputs are flat (i.e. unit
       -- segment). This is equivalent to the old flat NestJoin rewrite.
       VProp UnitSegP <- segProp <$> properties $(v "xs")
       VProp UnitSegP <- segProp <$> properties $(v "ys")
       VProp UnitSegP <- segProp <$> properties $(v "zs")

       return $ do
         logRewrite "Redundant.Prop.NestJoinChain" q


         let e = TMkTuple [ TTupElem (Next First) (TTupElem First TInput)
                          , TTupElem (Next First) TInput
                          ]

             -- As the left input of the top nestjoin now includes the
             -- columns from xs, we have to shift column references in
             -- the left predicate side.
             p' = partialEval <$> inlineJoinPredLeft (TTupElem (Next First) TInput) $(v "p")

         -- The R1 node on the left nest join might already exist, but
         -- we simply rely on hash consing.
         leftJoinR1    <- insert $ UnOp R1 $(v "lj")

         -- Since we employ the per-segment NestJoin, we have to unsegment the
         -- left join result that is to be joined with the rightmost input (zs).
         -- Otherwise, the segment structure of the left join result would not
         -- match that of zs, which is guaranteed to consist of the unit
         -- segment.
         --
         -- Note that the middle result vector still is the original segmented
         -- result of the left join.
         unsegmentLeft <- insert $ UnOp Unsegment leftJoinR1

         rightJoin     <- insert $ BinOp (NestJoin p') unsegmentLeft $(v "zs")
         rightJoinR1   <- insert $ UnOp R1 rightJoin

         -- Because the original produced only the columns of ys and
         -- zs in the PropReorder output, we have to remove the xs
         -- columns from the top NestJoin.
         void $ replaceWithNew q $ UnOp (Project e) rightJoinR1 |])

--------------------------------------------------------------------------------
-- Eliminating operators whose output is not required

-- notReqNumber :: SLRule TExpr TExpr Properties
-- notReqNumber q =
--   $(dagPatMatch 'q "Number (q1)"
--     [| do
--         w <- vectorWidth . vectorTypeProp . bu <$> properties $(v "q1")
--         VProp (Just reqCols) <- reqColumnsProp . td <$> properties $(v "q")

--         -- The number output in column w + 1 must not be required
--         predicate $ all (<= w) reqCols

--         return $ do
--           logRewrite "Redundant.Req.Number" q
--           -- Add a dummy column instead of the number output to keep
--           -- column references intact.
--           let proj = map Column [1..w] ++ [Constant $ IntV 0xdeadbeef]
--           void $ replaceWithNew q $ UnOp (Project proj) $(v "q1") |])

--------------------------------------------------------------------------------
-- Classical relational algebra rewrites

-- | Merge a selection that refers to both sides of a cartesian
-- product operators' inputs into a join.
selectCartProd :: SLRule TExpr TExpr ()
selectCartProd q =
  $(dagPatMatch 'q "R1 (Select p (R1 ((q1) CartProduct (q2))))"
    [| do
        TBinApp (SBRelOp op) e1 e2 <- return $(v "p")

        -- The left operand column has to be from the left input, the
        -- right operand from the right input.
        predicate $ idxOnly (== First) e1
        predicate $ idxOnly (== (Next First)) e2

        return $ do
            logRewrite "Redundant.Relational.Join" q
            let e1' = partialEval $ mergeExpr (TMkTuple [TInput, TInput]) e1
            let e2' = partialEval $ mergeExpr (TMkTuple [TInput, TInput]) e2
            let joinPred = singlePred $ JoinConjunct e1' op e2'
            joinNode <- insert $ BinOp (ThetaJoin joinPred) $(v "q1") $(v "q2")
            void $ replaceWithNew q $ UnOp R1 joinNode |])

--------------------------------------------------------------------------------
-- Early aggregation of segments. We try to aggregate segments as early as
-- possible by pushing down segment aggregation operators through segment
-- propagation operators. Aggregating early means that the cardinality of inner
-- vectors is reduced. Ideally, we will be able to merge the Fold operator with
-- nesting operators (Group, NestJoin) and thereby avoid the materialization of
-- inner segments altogether.
--
-- Amongst others, these rewrites are important to deal with HAVING-like
-- patterns.

pushFoldAppMap :: SLRule TExpr TExpr ()
pushFoldAppMap q =
    $(dagPatMatch 'q "Fold agg (R1 ((qm) [AppRep | AppSort | AppFilter]@op (qv)))"
      [| do
            return $ do
                logRewrite "Redundant.Fold.Push.AppMap" q
                aggNode <- insert $ UnOp (Fold $(v "agg")) $(v "qv")
                appNode <- insert $ BinOp $(v "op") $(v "qm") aggNode
                void $ replaceWithNew q $ UnOp R1 appNode
       |])

pushFoldAppKey :: SLRule TExpr TExpr ()
pushFoldAppKey q =
    $(dagPatMatch 'q "Fold agg ((qm) AppKey (qv))"
      [| do
            return $ do
                logRewrite "Redundant.Fold.Push.AppKey" q
                aggNode <- insert $ UnOp (Fold $(v "agg")) $(v "qv")
                void $ replaceWithNew q $ BinOp AppKey $(v "qm") aggNode
       |])

-- FIXME duplicate all pushUnbox rewrites for unboxdefault
-- | Unbox singleton segments before they are filtered because of a selection.
-- This rewrite is valid because we only add columns at the end: column
-- references in the selection predicate remain valid.
pushUnboxSngSelect :: SLRule TExpr TExpr ()
pushUnboxSngSelect q =
  $(dagPatMatch 'q "R1 ((R1 (qs1=Select p (qo))) UnboxSng (R1 ((q2=R2 (qs2=Select _ (_))) AppFilter (qi))))"
    [| do
        predicate $ $(v "qs1") == $(v "qs2")
        return $ do
            logRewrite "Redundant.UnboxSng.Push.Select" q
            unboxNode  <- insert $ BinOp UnboxSng $(v "qo") $(v "qi")
            r1Node     <- insert $ UnOp R1 unboxNode
            selectNode <- insert $ UnOp (Select $(v "p")) r1Node
            void $ replaceWithNew q $ UnOp R1 selectNode |])

-- | Unbox singleton segments before a join (right input). This is an
-- improvement because the replication join is no longer necessary.
pushUnboxSngThetaJoinRight :: SLRule TExpr TExpr ()
pushUnboxSngThetaJoinRight q =
    $(dagPatMatch 'q "R1 (qu=(qr1=R1 (qj1=(qo1) ThetaJoin p (qo2))) UnboxSng (R1 ((R3 (qj2)) AppRep (qi))))"
      [| do
          predicate $ $(v "qj1") == $(v "qj2")
          return $ do
              logRewrite "Redundant.UnboxSng.Push.ThetaJoin.Right" q
              let p' = partialEval <$> inlineJoinPredRight (TTupElem First TInput) $(v "p")
              let te = TMkTuple [ TMkTuple [ TTupElem First TInput
                                           , TTupElem First (TTupElem (Next First) TInput)
                                           ]
                                , TTupElem (Next First) (TTupElem (Next First) TInput)
                                ]
              -- Insert unboxing in the right input of the join.
              unboxNode   <- insert $ BinOp UnboxSng $(v "qo2") $(v "qi")
              r1UnboxNode <- insert $ UnOp R1 unboxNode
              joinNode    <- insert $ BinOp (ThetaJoin p') $(v "qo1") r1UnboxNode
              r1JoinNode  <- insert $ UnOp R1 joinNode
              topProjNode <- insert $ UnOp (Project te) r1JoinNode
              replace q topProjNode

              -- Take care not to duplicate the join operator. We rewire all
              -- original parents to the new join operator and use a projection
              -- to keep the original schema.
              joinParents <- filter (/= $(v "qu")) <$> parents $(v "qr1")
              let compatProj = TMkTuple [TTupElem First TInput, TTupElem First (TTupElem (Next First) TInput)]
              projNode <- insert $ UnOp (Project compatProj) r1JoinNode
              forM_ joinParents $ \p -> replaceChild p $(v "qr1") projNode
      |])

--------------------------------------------------------------------------------
-- Normalization rules for segment aggregation

-- | Apply a singleton unbox operator before an align operator. By unboxing
-- early, we hope to be able to eliminate unboxing (e.g. by combining it with an
-- Fold and Group operator).
--
-- Note: We could either push into the left or right align input. For no good
-- reason, we choose the right side. When we deal with a self-align, this will
-- not matter. There might however be plans where the left side would make more
-- sense and we might get stuck.
pushUnboxSngAlign :: SLRule TExpr TExpr ()
pushUnboxSngAlign q =
  $(dagPatMatch 'q "R1 (((q1) Align (q2)) UnboxSng (q3))"
    [| return $ do
           logRewrite "Redundant.UnboxSng.Push.Align" q
           let e = TMkTuple [ TMkTuple [ TTupElem First TInput
                                       , TTupElem First (TTupElem (Next First) TInput)
                                       ]
                            , TTupElem (Next First) (TTupElem (Next First) TInput)
                            ]
           unboxNode <- insert $ BinOp UnboxSng $(v "q2") $(v "q3")
           r1Node    <- insert $ UnOp R1 unboxNode
           alignNode <- insert $ BinOp Align $(v "q1") r1Node
           void $ replaceWithNew q $ UnOp (Project e) alignNode
     |])

-- | Unbox singletons early, namely before distributing another singleton.
--
-- Note: the same comment as for pushUnboxSngAlign applies.
pushUnboxSngReplicateScalar :: SLRule TExpr TExpr ()
pushUnboxSngReplicateScalar q =
  $(dagPatMatch 'q "R1 ((R1 ((q1) ReplicateScalar (q2))) UnboxSng (q3))"
    [| return $ do
           logRewrite "Redundant.UnboxSng.Push.ReplicateScalar" q
           let e = TMkTuple [ TMkTuple [ TTupElem First TInput
                                       , TTupElem First (TTupElem (Next First) TInput)
                                       ]
                            , TTupElem (Next First) (TTupElem (Next First) TInput)
                            ]
           unboxNode <- insert $ BinOp UnboxSng $(v "q2") $(v "q3")
           r1Node    <- insert $ UnOp R1 unboxNode
           distNode  <- insert $ BinOp ReplicateScalar $(v "q1") r1Node
           r1Node'   <- insert $ UnOp R1 distNode
           void $ replaceWithNew q $ UnOp (Project e) r1Node'
     |])

--------------------------------------------------------------------------------

pullNumberReplicateNest :: SLRule TExpr TExpr ()
pullNumberReplicateNest q =
  $(dagPatMatch 'q "R1 ((q1) ReplicateNest (Number (q2)))"
    [| return $ do
          logRewrite "Redundant.ReplicateNest.Number" q
          let e = TMkTuple [ TFirst TInpFirst
                           , TMkTuple [ TSecond TInpFirst, TInpSecond ]
                           ]
          repNode    <- insert $ BinOp ReplicateNest $(v "q1") $(v "q2")
          r1Node     <- insert $ UnOp R1 repNode
          numberNode <- insert $ UnOp Number r1Node
          void $ replaceWithNew q $ UnOp (Project e) numberNode
     |])

pullNumberAlignLeft :: SLRule TExpr TExpr ()
pullNumberAlignLeft q =
  $(dagPatMatch 'q "(Number (q1)) Align (q2)"
     [| do
          return $ do
            logRewrite "Redundant.Align.Number.Left" q
            -- Project the number output between left and right columns to
            -- preserve the schema.
            let e = TMkTuple [ TMkTuple [ TFirst TInpFirst, TInpSecond ]
                             , TSecond TInpFirst
                             ]
            alignNode  <- insert $ BinOp Align $(v "q1") $(v "q2")
            numberNode <- insert $ UnOp Number alignNode
            void $ replaceWithNew q $ UnOp (Project e) numberNode
      |]
   )

pullNumberAlignRight :: SLRule TExpr TExpr ()
pullNumberAlignRight q =
  $(dagPatMatch 'q "(q1) Align (Number (q2))"
     [| do
          return $ do
            logRewrite "Redundant.Align.Number.Right" q
            let e = TMkTuple [ TFirst TInpFirst
                             , TMkTuple [ TSecond TInpFirst, TInpSecond ]
                             ]
            alignNode  <- insert $ BinOp Align $(v "q1") $(v "q2")
            numberNode <- insert $ UnOp Number alignNode
            void $ replaceWithNew q $ UnOp (Project e) numberNode
      |]
   )

stackedNumber :: SLRule TExpr TExpr ()
stackedNumber q =
  $(dagPatMatch 'q "Number (Number (q1))"
     [| do
             return $ do
                 logRewrite "Redundant.Number.Stacked" q
                 let e = TMkTuple [ TMkTuple [ TInpFirst, TInpSecond ], TInpSecond ]
                 numberNode <- insert $ UnOp Number $(v "q1")
                 void $ replaceWithNew q $ UnOp (Project e) numberNode
      |])

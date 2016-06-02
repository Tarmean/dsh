{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.VSL.Opt.Rewrite.Window where

-- FIXME window rewrites need to be based on NumberS instead of Number.

-- import           Control.Monad
import           Data.List.NonEmpty                        (NonEmpty (..))

-- import           Database.Algebra.Dag.Common

import qualified Database.DSH.Common.Lang                  as L
-- import           Database.DSH.Common.Opt
import           Database.DSH.Common.VectorLang
-- import           Database.DSH.VSL.Lang
-- import           Database.DSH.VSL.Opt.Properties.ReqColumns
-- import           Database.DSH.VSL.Opt.Properties.Types
-- import           Database.DSH.VSL.Opt.Properties.VectorType
-- import           Database.DSH.VSL.Opt.Rewrite.Common

pattern SingleJoinPred e1 op e2 = L.JoinPred ((L.JoinConjunct e1 op e2) :| [])
pattern DoubleJoinPred e11 op1 e12 e21 op2 e22 = L.JoinPred ((L.JoinConjunct e11 op1 e12)
                                                             :|
                                                             [L.JoinConjunct e21 op2 e22])
pattern AddExpr e1 e2 = BinApp (L.SBNumOp L.Add) e1 e2
pattern SubExpr e1 e2 = BinApp (L.SBNumOp L.Sub) e1 e2

aggrToWinFun :: AggrFun -> Maybe WinFun
aggrToWinFun (AggrSum _ e)         = Just $ WinSum e
aggrToWinFun (AggrMin e)           = Just $ WinMin e
aggrToWinFun (AggrMax e)           = Just $ WinMax e
aggrToWinFun (AggrAvg e)           = Just $ WinAvg e
aggrToWinFun (AggrAll e)           = Just $ WinAll e
aggrToWinFun (AggrAny e)           = Just $ WinAny e
aggrToWinFun AggrCount             = Just WinCount
aggrToWinFun (AggrCountDistinct _) = Nothing

-- Turn a running aggregate based on a self-join into a window operator.
-- runningAggWinUnbounded :: SLRule BottomUpProps
-- runningAggWinUnbounded q =
--   $(dagPatMatch 'q "R1 ((qo) UnboxSng ((_) AggrSeg afun (R1 ((qn=Number (q1)) NestJoin p (Number (q2))))))"
--     [| do
--         predicate $ $(v "q1") == $(v "q2")
--         predicate $ $(v "qo") == $(v "q1")

--         p1 <- properties $(v "q1")
--         VProp UnitSegP <- return $ segProp p1

--         let w = vectorWidth $ vectorTypeProp p1

--         -- We require a range predicate on the positions generated by
--         -- Number.
--         -- FIXME allow other forms of window specifications
--         SingleJoinPred (Column nrCol) L.GtE (Column nrCol') <- return $(v "p")
--         predicate $ nrCol == w + 1 && nrCol' == w + 1

--         -- The aggregate should only reference columns from the right
--         -- ThetaJoin input, i.e. columns from the partition generated
--         -- for a input tuple.
--         let isWindowColumn c = c >= w + 2 && c <= 2 * w + 1
--         predicate $ all isWindowColumn (aggrReqCols $(v "afun"))

--         -- Shift column references in aggregate functions so that they are
--         -- applied to partition columns.
--         Just afun' <- return $ aggrToWinFun $ mapAggrFun (mapExprCols (\c -> c - (w + 1))) $(v "afun")

--         return $ do
--             logRewrite "Window.RunningAggr" q
--             void $ replaceWithNew q $ UnOp (WinFun (afun', FAllPreceding)) $(v "q1") |])

-- runningAggWinUnboundedGroupJoin :: SLRule BottomUpProps
-- runningAggWinUnboundedGroupJoin q =
--   $(dagPatMatch 'q "(qn=Number (q1)) GroupJoin args (Number (q2))"
--     [| do
--         let (joinPred, afuns) = $(v "args")
--         afun :| [] <- return $ L.getNE afuns

--         predicate $ $(v "q1") == $(v "q2")

--         p1 <- properties $(v "q1")
--         VProp UnitSegP <- return $ segProp p1

--         let w = vectorWidth $ vectorTypeProp p1

--         -- We require a range predicate on the positions generated by
--         -- Number.
--         -- FIXME allow other forms of window specifications
--         SingleJoinPred (Column nrCol) L.GtE (Column nrCol') <- return joinPred
--         predicate $ nrCol == w + 1 && nrCol' == w + 1

--         Just wfun <- return $ (aggrToWinFun . mapAggrFun (mapExprCols (\c -> c - (w + 1)))) afun

--         return $ do
--             logRewrite "Window.RunningAggr.Unbounded" q
--             let winSpec = FAllPreceding

--             void $ replaceWithNew q $ UnOp (WinFun (wfun, winSpec)) $(v "qn") |])

-- -- Turn a running aggregate based on a self-join into a window operator.
-- -- FIXME merge with runningAggWinUnbounded
-- runningAggWinBounded :: SLRule BottomUpProps
-- runningAggWinBounded q =
--   $(dagPatMatch 'q "(qn=Number (q1)) GroupJoin args (Number (q2))"
--     [| do
--         let (joinPred, afuns) = $(v "args")
--         afun :| [] <- return $ L.getNE afuns

--         predicate $ $(v "q1") == $(v "q2")

--         p1 <- properties $(v "q1")
--         VProp UnitSegP <- return $ segProp p1

--         let w = vectorWidth $ vectorTypeProp p1

--         -- We require a range predicate on the positions generated by
--         -- Number.
--         -- FIXME allow other forms of window specifications
--         DoubleJoinPred e11 op1 e12 e21 op2 e22                 <- return joinPred
--         (SubExpr (Column nrCol) winSize, L.LtE, Column nrCol') <- return (e11, op1, e12)
--         (Column nrCol'', L.GtE, Column nrCol''')               <- return (e21, op2, e22)
--         Constant (L.IntV constWinSize)                         <- return winSize

--         predicate $ all (== (w + 1)) [nrCol, nrCol', nrCol'', nrCol''']

--         Just wfun <- return $ (aggrToWinFun . mapAggrFun (mapExprCols (\c -> c - (w + 1)))) afun

--         return $ do
--             logRewrite "Window.RunningAggr" q
--             let winSpec = FNPreceding constWinSize

--             void $ replaceWithNew q $ UnOp (WinFun (wfun, winSpec)) $(v "qn") |])

-- -- -- | Employ a window function that maps to SQL's first_value when the
-- -- -- 'head' combinator is employed on a nestjoin-generated window.
-- -- --
-- -- -- FIXME this rewrite is currently extremely ugly and fragile: We map
-- -- -- directly to first_value which produces only one value, but start
-- -- -- with head one potentially broader inputs. To bring them into sync,
-- -- -- we demand that only one column is required downstream and produce
-- -- -- that column. This involves too much fiddling with column
-- -- -- offsets. It would be less dramatic if we had name-based columns
-- -- -- (which we should really do).
-- -- firstValueWin :: SLRule Properties
-- -- firstValueWin q =
-- --   $(dagPatMatch 'q "(UnboxKey (Number (q1))) AppKey (R1 (SelectPos1S selectArgs (R1 ((Number (q2)) NestJoin joinPred (Number (q3))))))"
-- --     [| do
-- --         predicate $ $(v "q1") == $(v "q2") && $(v "q1") == $(v "q3")

-- --         inputWidth <- vectorWidth <$> vectorTypeProp <$> bu <$> properties $(v "q1")
-- --         resWidth   <- vectorWidth <$> vectorTypeProp <$> bu <$> properties $(v "q1")

-- --         VProp (Just [resCol]) <- reqColumnsProp <$> td <$> properties $(v "q")

-- --         -- Perform a sanity check (because this rewrite is rather
-- --         -- insane): the required column must originate from the inner
-- --         -- window created by the nestjoin and must not be the
-- --         -- numbering column.
-- --         predicate $ resCol > inputWidth + 1
-- --         predicate $ resCol < 2 * inputWidth + 2

-- --         -- The evaluation of first_value produces only a single value
-- --         -- for each input column. To employ first_value, the input has
-- --         -- to consist of a single column.

-- --         -- We expect the SL representation of 'head'
-- --         (SBRelOp Eq, 1) <- return $(v "selectArgs")

-- --         -- We expect a window specification that for each element
-- --         -- includes its predecessor (if there is one) and the element
-- --         -- itself.
-- --         DoubleJoinPred e11 op1 e12 e21 op2 e22                   <- return $(v "joinPred")
-- --         (SubExpr (Column nrCol) frameOffset, LtE, Column nrCol') <- return (e11, op1, e12)
-- --         (Column nrCol'', GtE, Column nrCol''')                   <- return (e21, op2, e22)
-- --         Constant (IntV offset)                                   <- return frameOffset

-- --         -- Check that all (assumed) numbering columns are actually the
-- --         -- column added by the Number operator.
-- --         predicate $ all (== (inputWidth + 1)) [nrCol, nrCol', nrCol'', nrCol''']

-- --         return $ do
-- --             logRewrite "Window.FirstValue" q
-- --             let -- The input column for FirstValue is the column in
-- --                 -- the inner window mapped to the input vector's
-- --                 -- layout.
-- --                 inputCol     = resCol - (inputWidth + 1)
-- --                 winArgs      = (WinFirstValue $ Column inputCol, (FNPreceding offset))
-- --                 placeHolders = repeat $ Constant $ IntV 0xdeadbeef

-- --                 -- Now comes the ugly stuff: to keep the schema intact
-- --                 -- (since columns are referred to by offset), we have
-- --                 -- to keep columns that are not required in place and
-- --                 -- replace them with placeholders.
-- --                 proj         = -- Unreferenced columns in front of the
-- --                                -- required column
-- --                                take (resCol - 1) placeHolders
-- --                                -- The required column (which is added
-- --                                -- by WinFun to the input columns
-- --                                ++ [Column (inputWidth + 1)]
-- --                                -- Unrefeferenced columns after the
-- --                                -- required column
-- --                                ++ take (resWidth - resCol) placeHolders
-- --             winNode <- insert $ UnOp (WinFun winArgs) $(v "q1")
-- --             void $ replaceWithNew q $ UnOp (Project proj) winNode |])

-- inlineWinAggrProject :: SLRule BottomUpProps
-- inlineWinAggrProject q =
--   $(dagPatMatch 'q "WinFun args (Project proj (q1))"
--     [| do
--         w <- vectorWidth <$> vectorTypeProp <$> properties $(v "q1")

--         return $ do
--             logRewrite "Window.RunningAggr.Project" q

--             let (afun, frameSpec) = $(v "args")
--                 env               = zip [1..] $(v "proj")
--                 -- Inline column expressions from the projection into
--                 -- the window function.
--                 afun'             = mapWinFun (mergeExpr env) afun

--                 -- WinAggr /adds/ the window function output to the
--                 -- input columns. We have to provide the schema of the
--                 -- input projection to which the window function
--                 -- output is added.
--                 proj' = $(v "proj") ++ [Column $ w + 1]

--             winNode <- insert $ UnOp (WinFun (afun', frameSpec)) $(v "q1")
--             void $ replaceWithNew q $ UnOp (Project proj') winNode |])

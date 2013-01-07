{-# LANGUAGE TemplateHaskell #-}

-- | This module provides the flattening implementation of DSH.
module Database.DSH.Flattening
  ( -- * Running queries via the Flattening backend
    fromQ
  , fromQX100
    -- * Debug functions
  , debugSQL
  , debugNKL
  , debugFKL
  , debugX100
  , debugNKLX100
  , debugFKLX100
  , debugVL
  , debugX100VL
  , debugPFXML
  ) where

import           GHC.Exts

import           Database.DSH.CompileFlattening
import           Database.DSH.ExecuteFlattening

import           Database.DSH.Internals
import           Database.HDBC
import qualified Database.HDBC                                   as H

import           Database.X100Client                             hiding (X100)
import qualified Database.X100Client                             as X

import qualified Database.DSH.Flattening.Common.Data.Type        as T
import           Database.DSH.Flattening.Export
import qualified Database.DSH.Flattening.NKL.Data.NKL            as NKL
import qualified Database.DSH.Flattening.NKL.Opt                 as NKLOpt
import           Database.DSH.Flattening.Translate.Algebra2Query
import           Database.DSH.Flattening.Translate.FKL2VL
import           Database.DSH.Flattening.Translate.NKL2FKL
import           Database.DSH.Flattening.Translate.VL2Algebra
import qualified Database.DSH.Flattening.VL.Data.Query           as Q

import qualified Data.List                                       as L

import           Control.Monad.State

import           Data.Convertible                                ()

(|>) :: a -> (a -> b) -> b
(|>) = flip ($)

-- Different versions of the flattening compiler pipeline

nkl2SQL :: NKL.Expr -> (Q.Query Q.SQL, T.Type)
nkl2SQL e = let (e', t) = nkl2Alg e
            in (generateSQL e', t)

nkl2Alg :: NKL.Expr -> (Q.Query Q.XML, T.Type)
nkl2Alg e = let q       = NKLOpt.opt e
                          |> flatten
                          |> specializeVectorOps
                          |> implementVectorOpsPF
                          |> generatePFXML
                t       = T.typeOf e
            in (q, t)

nkl2X100Alg :: NKL.Expr -> (Q.Query Q.X100, T.Type)
nkl2X100Alg e = let q = NKLOpt.opt e
                        |> flatten
                        |> specializeVectorOps
                        |> implementVectorOpsX100
                        |> generateX100Query
                    t = T.typeOf e
                in (q, t)

nkl2X100File :: String -> NKL.Expr -> IO ()
nkl2X100File prefix e = NKLOpt.opt e
                        |> flatten
                        |> specializeVectorOps
                        |> implementVectorOpsX100
                        |> (exportX100Plan prefix)

nkl2SQLFile :: String -> NKL.Expr -> IO ()
nkl2SQLFile prefix e = NKLOpt.opt e
                       |> flatten
                       |> specializeVectorOps
                       |> implementVectorOpsPF
                       |> generatePFXML
                       |> generateSQL
                       |> (exportSQL prefix)

nkl2XMLFile :: String -> NKL.Expr -> IO ()
nkl2XMLFile prefix e = NKLOpt.opt e
                       |> flatten
                       |> specializeVectorOps
                       |> implementVectorOpsPF
                       |> generatePFXML
                       |> (exportPFXML prefix)

nkl2VLFile :: String -> NKL.Expr -> IO ()
nkl2VLFile prefix e = NKLOpt.opt e
                      |> flatten
                      |> specializeVectorOps
                      |> exportVLPlan prefix

-- Functions for executing and debugging DSH queries via the Flattening backend

-- | Compile a DSH query to SQL and run it on the database given by 'c'.
fromQ :: (QA a, IConnection conn) => conn -> Q a -> IO a
fromQ c (Q a) =  do
                   (q, _) <- liftM nkl2SQL $ toNKL (getTableInfo c) a
                   fmap frExp $ executeSQLQuery c $ SQL q

-- | Compile a DSH query to X100 algebra and run it on the X100 server given by 'c'.
fromQX100 :: QA a => X100Info -> Q a -> IO a
fromQX100 c (Q a) =  do
                  (q, _) <- liftM nkl2X100Alg $ toNKL (getX100TableInfo c) a
                  fmap frExp $ executeX100Query c $ X100 q

-- | Debugging function: return the NKL (Nested Kernel Language) representation of a
-- query (SQL version)
debugNKL :: (QA a, IConnection conn) => conn -> Q a -> IO String
debugNKL c (Q e) = liftM show $ toNKL (getTableInfo c) e

-- | Debugging function: return the NKL (Nested Kernel Language) representation of a
-- query (X100 version)
debugNKLX100 :: QA a => X100Info -> Q a -> IO String
debugNKLX100 c (Q e) = liftM (show . flatten) $ toNKL (getX100TableInfo c) e

-- | Debugging function: return the FKL (Flat Kernel Language) representation of a
-- query (SQL version)
debugFKL :: (QA a, IConnection conn) => conn -> Q a -> IO String
debugFKL c (Q e) = liftM (show . flatten) $ toNKL (getTableInfo c) e

-- | Debugging function: return the FKL (Flat Kernel Language) representation of a
-- query (X100 version)
debugFKLX100 :: QA a => X100Info -> Q a -> IO String
debugFKLX100 c (Q e) = liftM (show . flatten) $ toNKL (getX100TableInfo c) e

-- | Debugging function: dumb the X100 plan (DAG) to a file.
debugX100 :: QA a => String -> X100Info -> Q a -> IO ()
debugX100 prefix c (Q e) = do
              e' <- toNKL (getX100TableInfo c) e
              nkl2X100File prefix e'

-- | Debugging function: dump the VL query plan (DAG) for a query to a file (SQL version).
debugVL :: (QA a, IConnection conn) => String -> conn -> Q a -> IO ()
debugVL prefix c (Q e) = do
  e' <- toNKL (getTableInfo c) e
  nkl2VLFile prefix e'

-- | Debugging function: dump the VL query plan (DAG) for a query to a file (X100 version).
debugX100VL :: QA a => String -> X100Info -> Q a -> IO ()
debugX100VL prefix c (Q e) = do
  e' <- toNKL (getX100TableInfo c) e
  nkl2VLFile prefix e'

-- | Debugging function: dump the Pathfinder Algebra query plan (DAG) to XML files.
debugPFXML :: (QA a, IConnection conn) => String -> conn -> Q a -> IO ()
debugPFXML prefix c (Q e) = do
  e' <- toNKL (getTableInfo c) e
  nkl2XMLFile prefix e'

-- | Debugging function: dump SQL queries generated by Pathfinder to files.
debugSQL :: (QA a, IConnection conn) => String -> conn -> Q a -> IO ()
debugSQL prefix c (Q e) = do
  e' <- toNKL (getTableInfo c) e
  nkl2SQLFile prefix e'

-- | Retrieve through the given database connection information on the table (columns with their types)
-- which name is given as the second argument.
getTableInfo :: IConnection conn => conn -> String -> IO [(String, (T.Type -> Bool))]
getTableInfo c n = do
                 info <- H.describeTable c n
                 return $ toTableDescr info

     where
       toTableDescr :: [(String, SqlColDesc)] -> [(String, (T.Type -> Bool))]
       toTableDescr = L.sortBy (\(n1, _) (n2, _) -> compare n1 n2) . map (\(name, props) -> (name, compatibleType (colType props)))
       compatibleType :: SqlTypeId -> T.Type -> Bool
       compatibleType dbT hsT = case hsT of
                                     T.Unit -> True
                                     T.Bool -> L.elem dbT [SqlSmallIntT, SqlIntegerT, SqlBitT]
                                     T.String -> L.elem dbT [SqlCharT, SqlWCharT, SqlVarCharT]
                                     T.Int -> L.elem dbT [SqlSmallIntT, SqlIntegerT, SqlTinyIntT, SqlBigIntT, SqlNumericT]
                                     T.Double -> L.elem dbT [SqlDecimalT, SqlRealT, SqlFloatT, SqlDoubleT]
                                     t       -> error $ "You can't store this kind of data in a table... " ++ show t ++ " " ++ show n

getX100TableInfo :: X100Info -> String -> IO [(String, (T.Type -> Bool))]
getX100TableInfo c n = do
                         t <- X.describeTable' c n
                         return [ col2Val col | col <- sortWith colName $ columns t]
        where
            col2Val :: ColumnInfo -> (String, T.Type -> Bool)
            col2Val col = (colName col, \t -> case logicalType col of
                                                LBool       -> t == T.Bool || t == T.Unit
                                                LInt1       -> t == T.Int  || t == T.Unit
                                                LUInt1      -> t == T.Int  || t == T.Unit
                                                LInt2       -> t == T.Int  || t == T.Unit
                                                LUInt2      -> t == T.Int  || t == T.Unit
                                                LInt4       -> t == T.Int  || t == T.Unit
                                                LUInt4      -> t == T.Int  || t == T.Unit
                                                LInt8       -> t == T.Int  || t == T.Unit
                                                LUInt8      -> t == T.Int  || t == T.Unit
                                                LInt16      -> t == T.Int  || t == T.Unit
                                                LUIDX       -> t == T.Nat  || t == T.Unit
                                                LDec        -> t == T.Double
                                                LFlt4       -> t == T.Double
                                                LFlt8       -> t == T.Double
                                                LMoney      -> t == T.Double
                                                LChar       -> t == T.String
                                                LVChar      -> t == T.String
                                                LDate       -> t == T.Int
                                                LTime       -> t == T.Int
                                                LTimeStamp  -> t == T.Int
                                                LIntervalDS -> t == T.Int
                                                LIntervalYM -> t == T.Int
                                                LUnknown s  -> error $ "Unknown DB type" ++ show s)


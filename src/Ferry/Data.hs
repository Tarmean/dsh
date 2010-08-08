{-# LANGUAGE ScopedTypeVariables
           , MultiParamTypeClasses
           , DeriveDataTypeable
           , FlexibleInstances #-}

module Ferry.Data where

import Data.Convertible
import Data.Typeable
import Database.HDBC
import Data.ByteString.Char8 (unpack)

data Exp =
    UnitE
  | BoolE Bool
  | CharE Char
  | IntE Int
  | TupleE Exp Exp
  | ListE [Exp]
  | VarE String
  | FuncE (Exp -> Exp)
  | AppE Exp Exp
  | TableE String Type

data Norm =
    UnitN
  | BoolN Bool
  | CharN Char
  | IntN Int
  | TupleN Norm Norm
  | ListN [Norm]
  deriving (Eq,Ord,Show, Typeable)

data Type =
    UnitT
  | IntT
  | BoolT
  | CharT
  | TupleT Type Type
  | ListT Type
  deriving (Eq, Show, Typeable)

data Q a = Q Exp

forget :: Q a -> Exp
forget (Q a) = a

instance Convertible Norm Exp where
    safeConvert n = Right $
        case n of
             UnitN          -> UnitE
             BoolN  b       -> BoolE b
             CharN c        -> CharE c
             IntN i         -> IntE i
             TupleN n1 n2   -> TupleE (normToExp n1) (normToExp n2)
             ListN ns       -> ListE (map normToExp ns)

normToExp :: Norm -> Exp
normToExp = convert

unfoldType :: Type -> [Type]
unfoldType (TupleT t1 t2) = t1 : unfoldType t2
unfoldType t = [t]


instance Convertible Type SqlTypeId where
    safeConvert n =
        case n of
             IntT           -> Right SqlBigIntT
             BoolT          -> Right SqlBitT
             CharT          -> Right SqlCharT
             ListT CharT    -> Right SqlVarCharT
             UnitT          -> convError "No `UnitT' representation" n
             TupleT {}      -> convError "No `TupleT' representation" n
             ListT {}       -> convError "No `ListT' representation" n

instance Convertible SqlTypeId Type where
    safeConvert n =
        case n of
             SqlBigIntT         -> Right IntT
             SqlBitT            -> Right BoolT
             SqlCharT           -> Right CharT
             SqlVarCharT        -> Right (ListT CharT)
             _                  -> convError "Unsupported `SqlTypeId'" n


instance Convertible SqlValue Norm where
    safeConvert sql =
        case sql of
             SqlNull            -> Right $ UnitN
             SqlInteger i       -> Right $ IntN (fromIntegral i)
             SqlBool b          -> Right $ BoolN b
             SqlChar c          -> Right $ CharN c
             SqlByteString s    -> Right $ ListN (map CharN $ unpack s)
             _                  -> convError "Unsupported `SqlValue'" sql

instance Convertible Norm SqlValue where
    safeConvert n =
        case n of
             UnitN                  -> Right $ SqlNull
             IntN i                 -> Right $ SqlInteger (fromIntegral i)
             BoolN b                -> Right $ SqlBool b
             CharN c                -> Right $ SqlChar c
             ListN [CharN c]        -> Right $ SqlString [c]
             ListN (CharN c : s)    -> case safeConvert (ListN s) of
                                            Right (SqlString s') -> Right (SqlString $ c : s')
                                            _                    ->
                                                convError "Only lists of `CharN' can be converted to `SqlString'" n
             _                      -> convError "Cannot convert `Norm' to `SqlValue'" n


instance Convertible (Maybe Norm) SqlValue where
    safeConvert Nothing  = Right SqlNull
    safeConvert (Just n) = safeConvert n

instance Convertible SqlValue (Maybe Norm) where
    safeConvert SqlNull = Right Nothing
    safeConvert s       = case (safeConvert s :: ConvertResult Norm) of
                               Right s'  -> Right $ Just s'
                               Left  err -> Left err

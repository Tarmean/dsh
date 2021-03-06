{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleContexts     #-}

module Database.DSH.Common.Lang where

import           Control.Monad.Except
import           Control.Monad.Reader
import           Data.Aeson
import           Data.Semigroup hiding (Sum)
import           Data.Aeson.TH
import qualified Data.List.NonEmpty           as N
import           Data.Scientific
import qualified Data.Text                    as T
import qualified Data.Time.Calendar           as C
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>),(<>))
import qualified Text.PrettyPrint.ANSI.Leijen as P
import           Text.Printf

import           Database.DSH.Common.Nat
import           Database.DSH.Common.Pretty
import           Database.DSH.Common.Type

-----------------------------------------------------------------------------
-- Common types for backend expressions

-- | Literal values
data Val = ListV    [Val]
         | TupleV   [Val]
         | ScalarV  ScalarVal
         deriving (Eq, Ord, Show)

instance FromJSON Date where
    parseJSON o = Date . (\(y, m, d) -> C.fromGregorian y m d) <$> parseJSON o

instance ToJSON Date where
    toJSON = toJSON . C.toGregorian . unDate

newtype Date = Date { unDate :: C.Day } deriving (Eq, Ord, Show)

data ScalarVal = IntV      {-# UNPACK #-} !Int
               | BoolV                    !Bool
               | StringV   {-# UNPACK #-} !T.Text
               | DoubleV   {-# UNPACK #-} !Double
               | DecimalV  {-# UNPACK #-} !Scientific
               | DateV                    !Date
               | UnitV
               deriving (Eq, Ord, Show)

$(deriveJSON defaultOptions ''ScalarVal)

litScalarTy :: ScalarVal -> ScalarType
litScalarTy IntV{}     = IntT
litScalarTy BoolV{}    = BoolT
litScalarTy StringV{}  = StringT
litScalarTy DoubleV{}  = DoubleT
litScalarTy DecimalV{} = DecimalT
litScalarTy DateV{}    = DateT
litScalarTy UnitV{}    = UnitT

instance Typed ScalarVal where
    typeOf = ScalarT . litScalarTy

newtype ColName = ColName String deriving (Eq, Ord, Show)

$(deriveJSON defaultOptions ''ColName)

-- | Typed table columns
type ColumnInfo = (ColName, ScalarType)

-- | Table keys
newtype Key = Key (N.NonEmpty ColName) deriving (Eq, Ord, Show)

$(deriveJSON defaultOptions ''Key)

-- | Is the table guaranteed to be not empty?
data Emptiness = NonEmpty
               | PossiblyEmpty
               deriving (Eq, Ord, Show)

$(deriveJSON defaultOptions ''Emptiness)

-- | Information about base tables
data BaseTableSchema = BaseTableSchema
    { tableCols     :: N.NonEmpty ColumnInfo
    , tableKeys     :: N.NonEmpty Key
    , tableNonEmpty :: Emptiness
    } deriving (Eq, Ord, Show)

$(deriveJSON defaultOptions ''BaseTableSchema)

-- | Identifiers
type Ident = String

-----------------------------------------------------------------------------

-- | A wrapper around 'NonEmpty' lists to avoid an orphan instance for 'Pretty'.
newtype NE a = NE { getNE :: N.NonEmpty a } deriving (Eq, Ord, Show)

instance Pretty a => Pretty (NE a) where
    pretty (NE xs) = pretty $ N.toList xs

instance Functor NE where
    fmap f (NE xs) = NE (fmap f xs)

instance Applicative NE where
    pure x = NE (pure x)
    (NE f) <*> (NE a) = NE (f <*> a)

instance Foldable NE where
    foldMap f (NE xs) = foldMap f xs

instance Semigroup (NE a) where
    NE xs <> NE ys = NE $ xs <> ys

$(deriveJSON defaultOptions ''NE)

-----------------------------------------------------------------------------
-- Scalar operators

data UnCastOp = CastDouble
              | CastDecimal
                deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''UnCastOp)

data UnBoolOp = Not
                deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''UnBoolOp)

data UnNumOp = Sin
             | Cos
             | Tan
             | ASin
             | ACos
             | ATan
             | Sqrt
             | Exp
             | Log
             deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''UnNumOp)

data UnTextOp = SubString Integer Integer
                deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''UnTextOp)

data UnDateOp = DateDay
              | DateMonth
              | DateYear
              deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''UnDateOp)

data ScalarUnOp = SUNumOp UnNumOp
                | SUBoolNot
                | SUCastOp UnCastOp
                | SUTextOp UnTextOp
                | SUDateOp UnDateOp
                deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''ScalarUnOp)

data BinNumOp = Add
              | Sub
              | Div
              | Mul
              | Mod
              deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''BinNumOp)

data BinRelOp = Eq
              | Gt
              | GtE
              | Lt
              | LtE
              | NEq
              deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''BinRelOp)

data BinBoolOp = Conj
               | Disj
                deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''BinBoolOp)

data BinStringOp = Like
                 | ReMatch
                 deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''BinStringOp)

data BinDateOp = AddDays
               | SubDays
               | DiffDays
               deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''BinDateOp)

-- FIXME this would be a good fit for PatternSynonyms
data ScalarBinOp = SBNumOp BinNumOp
                 | SBRelOp BinRelOp
                 | SBBoolOp BinBoolOp
                 | SBStringOp BinStringOp
                 | SBDateOp BinDateOp
                 deriving (Show, Eq, Ord)

$(deriveJSON defaultOptions ''ScalarBinOp)

-----------------------------------------------------------------------------
-- Aggregate

-- | AggrFun functions
data AggrFun = Length Bool | Avg | Minimum | Maximum | And | Or | Sum
    deriving (Eq, Show, Ord)

data AggrApp = AggrApp
    { aaFun      :: AggrFun
    , aaArg      :: ScalarExpr
    } deriving (Eq, Show, Ord)

aggType :: AggrApp -> Type
aggType (AggrApp af e) = aggFunType af $ typeOf e

aggFunType :: AggrFun -> Type -> Type
aggFunType Length{} _ = PIntT
aggFunType Sum ty     = ty
aggFunType Maximum ty = ty
aggFunType Minimum ty = ty
aggFunType Avg ty     = ty
aggFunType And _      = PBoolT
aggFunType Or _       = PBoolT

-----------------------------------------------------------------------------
-- Join operator arguments: limited expressions that can be used on joins

data JoinConjunct e = JoinConjunct
    { jcLeft  :: e
    , jcOp    :: BinRelOp
    , jcRight :: e
    } deriving (Show, Eq, Ord)

instance Functor JoinConjunct where
    fmap f jc = jc { jcLeft = f (jcLeft jc), jcRight = f (jcRight jc) }

instance ToJSON e => ToJSON (JoinConjunct e) where
    toJSON (JoinConjunct e1 op e2) = toJSON (e1, op, e2)

instance FromJSON e => FromJSON (JoinConjunct e) where
    parseJSON d = parseJSON d >>= \(e1, op, e2) -> return $ JoinConjunct e1 op e2

newtype JoinPredicate e = JoinPred { jpConjuncts :: N.NonEmpty (JoinConjunct e) }
    deriving (Show, Eq, Ord)

instance Functor JoinPredicate where
    fmap f jp = jp { jpConjuncts = fmap (fmap f) (jpConjuncts jp) }

instance Semigroup (JoinPredicate e) where
    (JoinPred p1) <> (JoinPred p2) = JoinPred (p1 <> p2)

instance ToJSON e => ToJSON (JoinPredicate e) where
    toJSON (JoinPred conjs) = toJSON conjs

instance FromJSON e => FromJSON (JoinPredicate e) where
    parseJSON d = parseJSON d >>= \conjs -> return $ JoinPred conjs

singlePred :: JoinConjunct e -> JoinPredicate e
singlePred c = JoinPred $ c N.:| []

data ScalarExpr = JBinOp ScalarBinOp ScalarExpr ScalarExpr
                | JUnOp ScalarUnOp ScalarExpr
                | JTupElem TupleIndex ScalarExpr
                | JIf ScalarExpr ScalarExpr ScalarExpr
                | JLit Type Val
                | JInput Type
              deriving (Show, Eq, Ord)

-- | Modify the input type of a scalar expression.
mapInput :: (Type -> Type) -> ScalarExpr -> ScalarExpr
mapInput f (JIf e1 e2 e3)    = JIf (mapInput f e1) (mapInput f e2) (mapInput f e3)
mapInput f (JBinOp op e1 e2) = JBinOp op (mapInput f e1) (mapInput f e2)
mapInput f (JUnOp op e)      = JUnOp op (mapInput f e)
mapInput f (JTupElem i e)    = JTupElem i (mapInput f e)
mapInput _ (JLit ty v)       = JLit ty v
mapInput f (JInput ty)       = JInput $ f ty

instance Typed ScalarExpr where
    typeOf (JIf e1 e2 e3)   = either error id $ inferCond (typeOf e1) (typeOf e2) (typeOf e3)
    typeOf (JBinOp o e1 e2) = either error id $ inferBinOp (typeOf e1) (typeOf e2) o
    typeOf (JUnOp o e)      = either error id $ inferUnOp (typeOf e) o
    typeOf (JTupElem i e)   = either error id $ inferTupleElem (typeOf e) i
    typeOf (JLit t _)       = t
    typeOf (JInput t)       = t

--------------------------------------------------------------------------------
-- Typing of scalar expressions and join predicates

data TypedSExpr = TE ScalarExpr Type

instance Pretty TypedSExpr where
    pretty (TE e ty) = pretty e P.<> char ':' P.<> pretty ty

tupElemTyErr :: TypedSExpr -> TupleIndex -> String
tupElemTyErr e i = printf "jExpTy: (%s).%d" (pp e) (tupleIndex i)

condTyErr :: TypedSExpr -> TypedSExpr -> TypedSExpr -> String
condTyErr e1 e2 e3 = printf "jExpTy: if %s then %s else %s" (pp e1) (pp e2) (pp e3)

unOpTyErr :: ScalarUnOp -> TypedSExpr -> String
unOpTyErr op e = printf "jExpTy: %s(%s)" (pp op) (pp e)

binOpTyErr :: ScalarBinOp -> TypedSExpr -> TypedSExpr -> String
binOpTyErr op e1 e2 = printf "jExpTy: (%s) %s (%s)" (pp e1) (pp op) (pp e2)

conjTyErr :: JoinConjunct TypedSExpr -> String
conjTyErr c = printf "predTy: (%s) %s (%s)" (pp $ jcLeft c) (pp $ jcOp c) (pp $ jcRight c)

jExpTy :: (MonadError String m, MonadReader (Maybe Type) m) => ScalarExpr -> m Type
jExpTy (JIf e1 e2 e3)   = do
    condTy <- jExpTy e1
    thenTy <- jExpTy e2
    elseTy <- jExpTy e3
    if condTy == ScalarT BoolT && thenTy == elseTy
       then pure thenTy
       else throwError $ condTyErr (TE e1 condTy) (TE e2 thenTy) (TE e3 elseTy)
jExpTy (JLit ty _)      = pure ty
jExpTy (JInput tyAnnot) = do
    mTy <- ask
    case mTy of
        Just ty | ty == tyAnnot -> pure ty
                | otherwise     -> throwError $ printf "jExpTy: input type mismatch: %s (input) /= %s (annot)" (pp ty) (pp tyAnnot)
        Nothing -> throwError "jExpTy: TInput with empty env"
jExpTy (JTupElem i e)     = do
    ty <- jExpTy e
    case ty of
        TupleT ts ->
            case safeIndex i ts of
                Just t  -> pure t
                Nothing -> throwError $ tupElemTyErr (TE e ty) i
        _          -> throwError $ tupElemTyErr (TE e ty) i
jExpTy (JBinOp op e1 e2) = do
    ty1 <- jExpTy e1
    ty2 <- jExpTy e2
    case (ty1, ty2) of
        (ScalarT sty1, ScalarT sty2) -> ScalarT <$> inferBinOpScalar sty1 sty2 op
        _                            -> throwError $ binOpTyErr op (TE e1 ty1) (TE e2 ty2)
jExpTy (JUnOp op e)      = do
    ty <- jExpTy e
    case ty of
        ScalarT sty -> ScalarT <$> inferUnOpScalar sty op
        _           -> throwError $ unOpTyErr op (TE e ty)

scJoinExpTyErr :: String -> ScalarExpr -> String
scJoinExpTyErr msg e = printf "Type error in scalar join expression %s\n%s" (pp e) msg

conjTy :: MonadError String m => Type -> Type -> JoinConjunct ScalarExpr -> m ()
conjTy ty1 ty2 c = do
    leftTy  <- catchError (runReaderT (jExpTy (jcLeft c)) (Just ty1))
                          (\msg -> throwError $ scJoinExpTyErr msg (jcLeft c))
    rightTy <- catchError (runReaderT (jExpTy (jcRight c)) (Just ty2))
                          (\msg -> throwError $ scJoinExpTyErr msg (jcRight c))
    if leftTy == rightTy
       then pure ()
       else throwError $ conjTyErr $ c { jcLeft = TE (jcLeft c) leftTy
                                       , jcRight = TE (jcRight c) rightTy
                                       }

checkPredTy :: MonadError String m => Type -> Type -> JoinPredicate ScalarExpr -> m ()
checkPredTy ty1 ty2 p = mapM_ (conjTy ty1 ty2) (jpConjuncts p)

--------------------------------------------------------------------------------
-- Typing of aggregate functions

aggFunTyErr :: AggrFun -> String
aggFunTyErr op = printf "tExpTy: %s" (pp op)

aggrTy :: (MonadError String m, MonadReader (Maybe Type) m) => AggrApp -> m Type
aggrTy (AggrApp Length{} e)    = void (jExpTy e) >> pure (ScalarT IntT)
aggrTy (AggrApp Sum e)         = jExpTy e
aggrTy (AggrApp Minimum e)     = jExpTy e
aggrTy (AggrApp Maximum e)     = jExpTy e
aggrTy (AggrApp Avg e)         = jExpTy e
aggrTy (AggrApp And e)         = do
    ty <- jExpTy e
    if ty == ScalarT BoolT
       then pure ty
       else throwError $ aggFunTyErr And
aggrTy (AggrApp Or e)   = do
    ty <- jExpTy e
    if ty == ScalarT BoolT
       then pure ty
       else throwError $ aggFunTyErr Or

--------------------------------------------------------------------------------
-- Typing of expressions

typeError :: (MonadError String m, Pretty a, Pretty b) => a -> [b] -> m b
typeError op argTys = throwError $ printf "type error for %s: %s" (pp op) (pp argTys)

inferTupleElem :: MonadError String m => Type -> TupleIndex -> m Type
inferTupleElem (TupleT ts) i
    | length ts >= tupleIndex i = pure $ ts !! (tupleIndex i - 1)
    | otherwise                 = throwError $ printf "type error for _.%d: %s" (tupleIndex i) (pp (TupleT ts))
inferTupleElem t i              = throwError $ printf "type error for _.%d: %s" (tupleIndex i) (pp t)

inferUnOpScalar :: MonadError String m => ScalarType -> ScalarUnOp -> m ScalarType
inferUnOpScalar t        (SUNumOp o)
    | isNum (ScalarT t)                            = pure t
    | otherwise                                    = typeError o [t]
inferUnOpScalar BoolT   SUBoolNot                  = pure BoolT
inferUnOpScalar t       SUBoolNot                  = typeError SUBoolNot [t]
inferUnOpScalar IntT    (SUCastOp CastDouble)      = pure DoubleT
inferUnOpScalar IntT    (SUCastOp CastDecimal)     = pure DecimalT
inferUnOpScalar t        (SUCastOp o)              = typeError o [t]
inferUnOpScalar StringT (SUTextOp (SubString _ _)) = pure StringT
inferUnOpScalar t        (SUTextOp o)              = typeError o [t]
inferUnOpScalar DateT   (SUDateOp _)               = pure IntT
inferUnOpScalar t        (SUDateOp o)              = typeError o [t]

inferUnOp :: MonadError String m => Type -> ScalarUnOp -> m Type
inferUnOp (ScalarT t) op = ScalarT <$> inferUnOpScalar t op
inferUnOp t           op = typeError op [t]

inferBinOpScalar :: MonadError String m => ScalarType -> ScalarType -> ScalarBinOp -> m ScalarType
inferBinOpScalar t1 t2 op =
    case op of
        SBNumOp o
            | isNum (ScalarT t1) && t1 == t2 -> pure t1
            | otherwise                      -> typeError o [t1, t2]
        SBRelOp o
            | t1 == t2                       -> pure BoolT
            | otherwise                      -> typeError o [t1, t2]
        SBBoolOp o
            | t1 == BoolT && t2 == BoolT     -> pure BoolT
            | otherwise                      -> typeError o [t1, t2]
        SBStringOp o
            | t1 == StringT && t2 == StringT -> pure BoolT
            | otherwise                      -> typeError o [t1, t2]
        SBDateOp AddDays
            | t1 == IntT && t2 == DateT      -> pure DateT
            | otherwise                      -> typeError AddDays [t1, t2]
        SBDateOp SubDays
            | t1 == IntT && t2 == DateT      -> pure DateT
            | otherwise                      -> typeError SubDays [t1, t2]
        SBDateOp DiffDays
            | t1 == DateT && t2 == DateT     -> pure IntT
            | otherwise                      -> typeError DiffDays [t1, t2]

inferBinOp :: MonadError String m => Type -> Type -> ScalarBinOp -> m Type
inferBinOp (ScalarT t1) (ScalarT t2) op = ScalarT <$> inferBinOpScalar t1 t2 op
inferBinOp t1           t2           op = typeError op [t1, t2]

inferCondScalar :: MonadError String m => ScalarType -> ScalarType -> ScalarType -> m ScalarType
inferCondScalar boolTy thenTy elseTy
    | boolTy == BoolT && thenTy == elseTy = pure thenTy
    | otherwise                           = typeError "if" [boolTy, thenTy, elseTy]

inferCond :: MonadError String m => Type -> Type -> Type -> m Type
inferCond (ScalarT t1) (ScalarT t2) (ScalarT t3) = ScalarT <$> inferCondScalar t1 t2 t3
inferCond t1           t2           t3           = typeError "if" [t1, t2, t3]

-----------------------------------------------------------------------------
-- Pretty-printing of stuff

parenthize :: ScalarExpr -> Doc
parenthize e =
    case e of
        JIf{}      -> parens $ pretty e
        JBinOp{}   -> parens $ pretty e
        JUnOp{}    -> parens $ pretty e
        JTupElem{} -> pretty e
        JLit{}     -> pretty e
        JInput{}   -> pretty e

instance Pretty Val where
    pretty (ListV xs)    = list $ map pretty xs
    pretty (TupleV vs)   = tupled $ map pretty vs
    pretty (ScalarV v)   = pretty v

instance Pretty ScalarVal where
    pretty (IntV i)        = int i
    pretty (BoolV b)       = bool b
    pretty (StringV t)     = dquotes $ string $ T.unpack t
    pretty (DoubleV d)     = double d
    pretty (DecimalV d)    = text $ show d
    pretty UnitV           = text "〈〉"
    pretty (DateV d)       = text $ C.showGregorian $ unDate d

instance Pretty BinRelOp where
    pretty Eq  = text "=="
    pretty Gt  = text ">"
    pretty Lt  = text "<"
    pretty GtE = text ">="
    pretty LtE = text "<="
    pretty NEq = text "/="

instance Pretty BinStringOp where
    pretty Like    = text "LIKE"
    pretty ReMatch = text "~"

instance Pretty BinNumOp where
    pretty Add = text "+"
    pretty Sub = text "-"
    pretty Div = text "/"
    pretty Mul = text "*"
    pretty Mod = text "%"

instance Pretty BinBoolOp where
    pretty Conj = text "&&"
    pretty Disj = text "||"


instance Pretty BinDateOp where
    pretty AddDays  = text "addDays"
    pretty SubDays  = text "subDays"
    pretty DiffDays = text "diffDays"

isBinInfixOp :: ScalarBinOp -> Bool
isBinInfixOp op =
    case op of
        SBNumOp{}    -> True
        SBRelOp{}    -> True
        SBBoolOp{}   -> True
        SBStringOp{} -> False
        SBDateOp{}   -> False

instance Pretty UnNumOp where
    pretty Sin  = text "sin"
    pretty Cos  = text "cos"
    pretty Tan  = text "tan"
    pretty Sqrt = text "sqrt"
    pretty Exp  = text "exp"
    pretty Log  = text "log"
    pretty ASin = text "asin"
    pretty ACos = text "acos"
    pretty ATan = text "atan"

instance Pretty UnCastOp where
    pretty CastDouble  = text "double"
    pretty CastDecimal = text "decimal"

instance Pretty UnDateOp where
    pretty DateDay   = text "dateDay"
    pretty DateMonth = text "dateMonth"
    pretty DateYear  = text "dateYear"

instance Pretty ScalarExpr where
    pretty (JIf e1 e2 e3)    = text "if" <+> pretty e1 <+> text "then" <+> pretty e2 <+> text "else" <+> pretty e3
    pretty (JBinOp op e1 e2) = parenthize e1 <+> pretty op <+> parenthize e2
    pretty (JUnOp op e)      = pretty op <+> parenthize e
    pretty (JLit _ v)        = pretty v
    pretty (JInput _)        = text "I"
    pretty (JTupElem i e1)   =
        parenthize e1 P.<> dot P.<> int (tupleIndex i)

instance Pretty e => Pretty (JoinConjunct e) where
    pretty (JoinConjunct e1 op e2) = pretty e1 <+> pretty op <+> pretty e2

instance Pretty e => Pretty (JoinPredicate e) where
    pretty (JoinPred ps) = hcat $ punctuate (text " && ") $ map pretty $ N.toList ps

instance Pretty ScalarBinOp where
    pretty (SBNumOp o)    = pretty o
    pretty (SBRelOp o)    = pretty o
    pretty (SBBoolOp o)   = pretty o
    pretty (SBStringOp o) = pretty o
    pretty (SBDateOp o)   = pretty o

instance Pretty UnBoolOp where
    pretty Not = text "not"

instance Pretty ScalarUnOp where
    pretty (SUNumOp op)  = pretty op
    pretty SUBoolNot     = text "not"
    pretty (SUCastOp op) = pretty op
    pretty (SUDateOp op) = pretty op
    pretty (SUTextOp op) = pretty op

instance Pretty UnTextOp where
    pretty (SubString f t) = text $ printf "subString_%d,%d" f t

instance Pretty AggrFun where
  pretty (Length True)   = combinator $ text "length_d"
  pretty (Length False)  = combinator $ text "length"
  pretty Sum             = combinator $ text "sum"
  pretty Avg             = combinator $ text "avg"
  pretty Minimum         = combinator $ text "minimum"
  pretty Maximum         = combinator $ text "maximum"
  pretty And             = combinator $ text "and"
  pretty Or              = combinator $ text "or"

instance Pretty AggrApp where
    pretty aa = pretty (aaFun aa) P.<> parens (pretty $ aaArg aa)


--------------------------------------------------------------------------------

-- | Singleton list literal [()]
sngUnitList :: (Type, Val)
sngUnitList = (ListT $ ScalarT UnitT, ListV [ScalarV UnitV])

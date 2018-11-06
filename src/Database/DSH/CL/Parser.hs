-- | A parser for comprehension language (CL) expressions.
--
-- @
-- Types:
--
-- t ::= [t] | (t, ..., t) | bt
--
-- Base types:
--
-- bt ::= Int | Double | Decimal | String | Char | Bool | ()
--
-- Expressions:
--
-- e ::= table(n, s, k)::t
--     | (prim1 e)::t
--     | (prim2 e e)::t
--     | (prefixOp e)::t
--     | (e infixOp e)::t
--     | (if e then e else e)::t
--     | l::t
--     | n::t
--     | [ e | qs ]::t
--     | (e, ..., e)::t
--     | e.[1-9][0-9]*::t
--     | (let x = e in e)::t
--     | (e).n::t
--
-- Comprehension qualifiers:
--
-- qs ::= x <- e, qs | e, qs | x <- e | e
--
-- Schema:
--
-- s ::= [ n::bt, ... ]
--
-- Keys:
--
-- k ::= [ [n, ...], ...]
--
-- Identifiers:
--
-- n ::= [a-zA-Z0-9]+
-- @

module Database.DSH.CL.Parser
    ( parseCL
    , typedExpr
    ) where

-- import           Control.Applicative
import           Control.Monad
import           Data.List.NonEmpty       (NonEmpty ((:|)))
import qualified Data.List.NonEmpty       as N
import qualified Data.Text                as T

import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer    as Lex

import           Database.DSH.CL.Lang
import qualified Database.DSH.Common.Lang as L
import qualified Database.DSH.Common.Nat  as N
import qualified Database.DSH.Common.Type as T
import Data.Void

type CLParser a = Parsec Void String a

--------------------------------------------------------------------------------
-- Lexer infrastructure

spaceConsumer :: CLParser ()
spaceConsumer = Lex.space (void spaceChar) empty empty

symbol :: String -> CLParser String
symbol = Lex.symbol spaceConsumer

lexeme :: CLParser a -> CLParser a
lexeme = Lex.lexeme spaceConsumer

parens :: CLParser a -> CLParser a
parens = between (symbol "(") (symbol ")")

brackets :: CLParser a -> CLParser a
brackets = between (symbol "[") (symbol "]")

colon :: CLParser ()
colon = void $ symbol ":"

pipe :: CLParser ()
pipe = void $ symbol "|"

comma :: CLParser ()
comma = void $ symbol ","

ident :: CLParser String
ident = lexeme ((:) <$> lowerChar <*> many alphaNumChar)

kw :: String -> CLParser ()
kw s = void $ lexeme (string s)

sep :: CLParser ()
sep = spaceConsumer

integerLit :: CLParser Int
integerLit = fromIntegral <$> lexeme Lex.decimal

boolLit :: CLParser Bool
boolLit = kw "True" *> pure True <|> kw "False" *> pure False

stringLit :: CLParser String
stringLit = char '"' >> manyTill Lex.charLiteral (char '"')

doubleLit :: CLParser Double
doubleLit = lexeme Lex.float

unitLit :: CLParser ()
unitLit = void $ lexeme $ string "()"

--------------------------------------------------------------------------------
-- Parsing helpers

list :: CLParser a -> CLParser [a]
list p = brackets (p `sepBy` comma)

nonEmpty :: CLParser a -> CLParser (N.NonEmpty a)
nonEmpty p = brackets $ (:|) <$> p <*> ((comma *> p `sepBy` comma) <|> pure [])

tuple :: CLParser a -> CLParser [a]
tuple p = parens (p `sepBy1` comma)

kwConst :: String -> a -> CLParser a
kwConst s c = kw s *> pure c

--------------------------------------------------------------------------------
-- Types

baseType :: CLParser ScalarType
baseType =     try (kw "Int" *> pure T.IntT)
           <|> try (kw "Bool" *> pure T.BoolT)
           <|> try (kw "Double" *> pure T.DoubleT)
           <|> try (kw "()" *> pure T.UnitT)
           <|> try (kw "Decimal" *> pure T.DecimalT)
           <|> try (kw "Date" *> pure T.DateT)
           <|> try (kw "String" *> pure T.StringT)

typeExpr :: CLParser T.Type
typeExpr =     T.ListT <$> brackets typeExpr
           <|> try (T.ScalarT <$> baseType)
           <|> T.TupleT <$> tuple typeExpr

typeAnnotation :: CLParser a -> CLParser a
typeAnnotation p = colon >> colon >> p

--------------------------------------------------------------------------------
-- Table references

colName :: CLParser L.ColName
colName = L.ColName <$> ident

tableCols :: CLParser (N.NonEmpty L.ColumnInfo)
tableCols = nonEmpty $ (,) <$> colName <*> typeAnnotation baseType

tableKeys :: CLParser (N.NonEmpty L.Key)
tableKeys = nonEmpty $ L.Key <$> nonEmpty colName

baseTableSchema :: CLParser L.BaseTableSchema
baseTableSchema = do
    cols      <- tableCols
    void comma
    keys      <- tableKeys
    return $ L.BaseTableSchema cols keys L.PossiblyEmpty

tableRef :: CLParser (Type -> Expr)
tableRef = do
    void $ string "table"
    (tabName, schema) <- parens ((,) <$> ident <*> (comma *> baseTableSchema))
    return $ \ty -> Table ty tabName schema

--------------------------------------------------------------------------------
-- Primitive functions:w

prim1 :: CLParser Prim1
prim1 =     try (kw "singleton" *> pure Singleton)
        <|> try (kw "only" *> pure Only)
        <|> try (kw "length" *> pure (Agg (L.Length False)))
        <|> try (kw "concat" *> pure Concat)
        <|> try (kw "null" *> pure Null)
        <|> try (kw "sum" *> pure (Agg L.Sum))
        <|> try (kw "avg" *> pure Only)
        <|> try (kw "minimum" *> pure (Agg L.Minimum))
        <|> try (kw "maximum" *> pure (Agg L.Maximum))
        <|> try (kw "reverse" *> pure Reverse)
        <|> try (kw "and" *> pure (Agg L.And))
        <|> try (kw "or" *> pure (Agg L.Or))
        <|> try (kw "nub" *> pure Nub)
        <|> try (kw "number" *> pure Number)
        <|> try (kw "only" *> pure Only)
        <|> try (kw "sort" *> pure Sort)
        <|> try (kw "group" *> pure Group)

prim2 :: CLParser (Expr -> Expr -> Type -> Expr)
prim2 =     try (kw "append"   *> pure (\e1 e2 t -> AppE2 t Append e1 e2))
        <|> try (kw "zip"      *> pure (\e1 e2 t -> AppE2 t Zip e1 e2))
        <|> try (kw "diffDays" *> pure (\e1 e2 t -> BinOp t (L.SBDateOp L.DiffDays) e1 e2))
        <|> try (kw "addDays"  *> pure (\e1 e2 t -> BinOp t (L.SBDateOp L.AddDays) e1 e2))

--------------------------------------------------------------------------------
-- Literals

baseLit :: CLParser L.ScalarVal
baseLit =     try (L.DoubleV <$> doubleLit)
          <|> try (L.IntV <$> integerLit)
          <|> try (L.BoolV <$> boolLit)
          <|> try (L.StringV . T.pack <$> stringLit)
          <|> try (unitLit *> pure L.UnitV)

literal :: CLParser L.Val
literal =     try (L.ScalarV <$> baseLit)
          <|> try (L.ListV <$> list literal)
          <|> try (L.TupleV <$> tuple literal)

--------------------------------------------------------------------------------
-- Infix operators
binNumOp :: CLParser L.BinNumOp
binNumOp =     try (kwConst "+" L.Add)
           <|> try (kwConst "-" L.Sub)
           <|> try (kwConst "/" L.Div)
           <|> try (kwConst "*" L.Mul)
           <|> try (kwConst "%" L.Mod)

binRelOp :: CLParser L.BinRelOp
binRelOp =     try (kwConst "==" L.Eq)
           <|> try (kwConst ">" L.Gt)
           <|> try (kwConst ">=" L.GtE)
           <|> try (kwConst "<" L.Lt)
           <|> try (kwConst "<=" L.LtE)
           <|> try (kwConst "!=" L.NEq)

infixOp :: CLParser L.ScalarBinOp
infixOp = L.SBNumOp <$> binNumOp <|> L.SBRelOp <$> binRelOp

--------------------------------------------------------------------------------
-- Prefix operators

prefixNumOp :: CLParser L.UnNumOp
prefixNumOp = kwConst "sin" L.Sin

prefixOp :: CLParser L.ScalarUnOp
prefixOp = L.SUNumOp <$> prefixNumOp

--------------------------------------------------------------------------------
-- Parsing of expressions

app1 :: CLParser (Type -> Expr)
app1 = (\p e t -> AppE1 t p e) <$> prim1 <*> (sep *> typedExpr)

app2 :: CLParser (Type -> Expr)
app2 = prim2 <*> (sep *> typedExpr) <*> (sep *> typedExpr)

infixApp :: CLParser (Type -> Expr)
infixApp = (\e1 op e2 t -> BinOp t op e1 e2) <$> typedExpr <*> infixOp <*> typedExpr

prefixApp :: CLParser (Type -> Expr)
prefixApp = (\op e t -> UnOp t op e) <$> prefixOp <*> typedExpr

ifExpr :: CLParser (Type -> Expr)
ifExpr = do
    kw "if"
    condExpr <- typedExpr
    kw "then"
    thenExpr <- typedExpr
    kw "else"
    elseExpr <- typedExpr
    return $ \ty -> If ty condExpr thenExpr elseExpr

expr :: CLParser (Type -> Expr)
expr = try app1 <|> try app2 <|> try infixApp <|> try prefixApp <|> try ifExpr <|> try letExpr

qualifier :: CLParser Qual
qualifier = try (BindQ <$> ident <*> (symbol "<-" *> typedExpr))
            <|> try (GuardQ <$> typedExpr)

comprehension :: CLParser (Type -> Expr)
comprehension = brackets $ do
    headExpr <- typedExpr
    pipe
    quals <- qualifier `sepBy1` comma
    case quals of
        []     -> mzero
        (q:qs) -> return $ \ty -> Comp ty headExpr (fromListSafe q qs)

letExpr :: CLParser (Type -> Expr)
letExpr = do
    kw "let"
    x         <- ident
    void $ symbol "="
    boundExpr <- typedExpr
    kw "in"
    inExpr    <- typedExpr
    return $ \ty -> Let ty x boundExpr inExpr

tupleExpr :: CLParser (Type -> Expr)
tupleExpr = flip MkTuple <$> parens (typedExpr `sepBy1` comma)

annotatedExpr :: CLParser Expr
annotatedExpr = do
    exprConst <- parens expr
    ty        <- typeAnnotation typeExpr
    return $ exprConst ty

tupElemExpr:: CLParser (Type -> Expr)
tupElemExpr =
    (\e i t -> AppE1 t (TupElem i) e)
        <$> (parens typedExpr <* char '.')
        <*> (N.intIndex <$> integerLit)

typedExpr :: CLParser Expr
typedExpr =     try (tableRef <*> typeAnnotation typeExpr)
            <|> try annotatedExpr
            <|> try (flip Lit <$> literal <*> typeAnnotation typeExpr)
            <|> try (flip Var <$> ident <*> typeAnnotation typeExpr)
            <|> try (comprehension <*> typeAnnotation typeExpr)
            <|> try (tupleExpr <*> typeAnnotation typeExpr)
            <|> try (tupElemExpr <*> typeAnnotation typeExpr)
            <|> try (parens typedExpr)

parseCL :: String -> Either String Expr
parseCL inp = case parseMaybe typedExpr inp of
    Nothing -> Left "parse error"
    Just e  -> Right e

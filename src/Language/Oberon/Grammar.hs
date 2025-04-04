{-# Language DeriveDataTypeable, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving,
             OverloadedStrings, Rank2Types, RecordWildCards, ScopedTypeVariables,
             TypeApplications, TypeFamilies, TypeSynonymInstances, TemplateHaskell #-}

-- | Oberon grammar adapted from http://www.ethoberon.ethz.ch/EBNF.html
-- 
-- Extracted from the book Programmieren in Oberon - Das neue Pascal by N. Wirth and M. Reiser and translated by
-- J. Templ.
--
-- The grammars in this module attempt to follow the language grammars from the reports, while generating a
-- semantically meaningful abstract syntax tree; the latter is defined in "Language.Oberon.AST". As the grammars are
-- ambiguous, it is necessary to resolve the ambiguities after parsing all Oberon modules in use.
-- "Language.Oberon.Resolver" provides this functionality. Only after the ambiguity resolution can the abstract syntax
-- tree be pretty-printed using the instances from "Language.Oberon.Pretty". Alternatively, since the parsing
-- preserves the original parsed lexemes including comments in the AST, you can use "Language.Oberon.Reserializer" to
-- reproduce the original source code from the AST.

module Language.Oberon.Grammar (OberonGrammar(..), Parser, NodeWrap, ParsedLexemes(..), Lexeme(..), TokenType(..),
                                oberonGrammar, oberon2Grammar, oberonDefinitionGrammar, oberon2DefinitionGrammar) where

import Control.Applicative
import Control.Arrow (first)
import Control.Monad (guard)
import Data.Char
import Data.Data (Data)
import Data.Functor.Compose (Compose(..))
import Data.List.NonEmpty (NonEmpty)
import Data.Ord (Down)
import Data.Maybe (catMaybes)
import Data.Monoid ((<>), Dual(Dual, getDual), Endo(Endo, appEndo))
import Numeric (readDec, readHex, readFloat)
import Data.Text (Text, unpack)
import Text.Grampa
import Text.Parser.Combinators (sepBy, sepBy1, sepByNonEmpty, try)
import Text.Grampa.ContextFree.LeftRecursive.Transformer (ParserT, lift, tmap)
import Text.Parser.Token (braces, brackets, parens)

import qualified Rank2.TH

import qualified Language.Oberon.Abstract as Abstract
import qualified Language.Oberon.AST as AST

import Prelude hiding (length, takeWhile)

-- | All the productions of the Oberon grammar
data OberonGrammar l f p = OberonGrammar {
   module_prod :: p (f (Abstract.Module l l f f)),
   ident :: p Abstract.Ident,
   letter :: p Text,
   digit :: p Text,
   importList :: p [Abstract.Import l],
   import_prod :: p (Abstract.Import l),
   declarationSequence :: p [f (Abstract.Declaration l l f f)],
   constantDeclaration :: p (Abstract.Declaration l l f f),
   identdef :: p (Abstract.IdentDef l),
   constExpression :: p (f (Abstract.Expression l l f f)),
   expression :: p (f (Abstract.Expression l l f f)),
   simpleExpression :: p (f (Abstract.Expression l l f f)),
   term :: p (f (Abstract.Expression l l f f)),
   factor :: p (f (Abstract.Expression l l f f)),
   number :: p (Abstract.Value l l f f),
   integer :: p (Abstract.Value l l f f),
   hexDigit :: p Text,
   real :: p (Abstract.Value l l f f),
   scaleFactor :: p Text,
   charConstant :: p (Abstract.Value l l f f),
   string_prod :: p Text,
   set :: p (Abstract.Expression l l f f),
   element :: p (Abstract.Element l l f f),
   designator :: p (f (Abstract.Designator l l f f)),
   unguardedDesignator :: p (Abstract.Designator l l f f),
   expList :: p (NonEmpty (f (Abstract.Expression l l f f))),
   actualParameters :: p [f (Abstract.Expression l l f f)],
   mulOperator :: p (BinOp l f),
   addOperator :: p (BinOp l f),
   relation :: p Abstract.RelOp,
   typeDeclaration :: p (Abstract.Declaration l l f f),
   type_prod :: p (Abstract.Type l l f f),
   qualident :: p (Abstract.QualIdent l),
   arrayType :: p (Abstract.Type l l f f),
   length :: p (f (Abstract.Expression l l f f)),
   recordType :: p (Abstract.Type l l f f),
   baseType :: p (Abstract.BaseType l),
   fieldListSequence :: p [f (Abstract.FieldList l l f f)],
   fieldList :: p (Abstract.FieldList l l f f),
   identList :: p (Abstract.IdentList l),
   pointerType :: p (Abstract.Type l l f f),
   procedureType :: p (Abstract.Type l l f f),
   variableDeclaration :: p (Abstract.Declaration l l f f),
   procedureDeclaration :: p (Abstract.Declaration l l f f),
   procedureHeading :: p (Abstract.Ident, Abstract.ProcedureHeading l l f f),
   formalParameters :: p (Abstract.FormalParameters l l f f),
   fPSection :: p (Abstract.FPSection l l f f),
   formalType :: p (Abstract.Type l l f f),
   procedureBody :: p (Abstract.Block l l f f),
   forwardDeclaration :: p (Abstract.Declaration l l f f),
   statementSequence :: p (Abstract.StatementSequence l l f f),
   statement :: p (f (Abstract.Statement l l f f)),
   assignment :: p (Abstract.Statement l l f f),
   procedureCall :: p (Abstract.Statement l l f f),
   ifStatement :: p (Abstract.Statement l l f f),
   caseStatement :: p (Abstract.Statement l l f f),
   case_prod :: p (Abstract.Case l l f f),
   caseLabelList :: p (NonEmpty (f (Abstract.CaseLabels l l f f))),
   caseLabels :: p (Abstract.CaseLabels l l f f),
   whileStatement :: p (Abstract.Statement l l f f),
   repeatStatement :: p (Abstract.Statement l l f f),
   forStatement :: p (Abstract.Statement l l f f),
   loopStatement :: p (Abstract.Statement l l f f),
   withStatement :: p (Abstract.Statement l l f f)}

newtype BinOp l f = BinOp {applyBinOp :: (f (Abstract.Expression l l f f)
                                          -> f (Abstract.Expression l l f f)
                                          -> f (Abstract.Expression l l f f))}

instance Show (BinOp l f) where
   show = const "BinOp{}"

$(Rank2.TH.deriveAll ''OberonGrammar)

type Parser = ParserT ((,) [[Lexeme]])
data Lexeme = WhiteSpace{lexemeText :: Text}
            | Comment{lexemeText :: Text}
            | Token{lexemeType :: TokenType,
                    lexemeText :: Text}
            deriving (Data, Eq, Show)

data TokenType = Delimiter | Keyword | Operator | Other
               deriving (Data, Eq, Show)

-- | Every node in the parsed AST will be wrapped in this data type.
type NodeWrap = Compose ((,) (Down Int, Down Int)) (Compose Ambiguous ((,) ParsedLexemes))

newtype ParsedLexemes = Trailing [Lexeme]
                      deriving (Data, Eq, Show, Semigroup, Monoid)

instance TokenParsing (Parser (OberonGrammar l f) Text) where
   someSpace = someLexicalSpace
   token = lexicalToken

instance LexicalParsing (Parser (OberonGrammar l f) Text) where
   lexicalComment = do c <- comment
                       lift ([[Comment c]], ())
   lexicalWhiteSpace = whiteSpace
   isIdentifierStartChar = isLetter
   isIdentifierFollowChar = isAlphaNum
   identifierToken word = lexicalToken (do w <- word
                                           guard (w `notElem` reservedWords)
                                           return w)
   lexicalToken p = snd <$> tmap addOtherToken (match p) <* lexicalWhiteSpace
      where addOtherToken ([], (i, x)) = ([[Token Other i]], (i, x))
            addOtherToken (t, (i, x)) = (t, (i, x))
   keyword s = lexicalToken (string s
                             *> notSatisfyChar (isIdentifierFollowChar @(Parser (OberonGrammar l f) Text))
                             <* lift ([[Token Keyword s]], ()))
               <?> ("keyword " <> show s)

comment :: Parser g Text Text
comment = try (string "(*"
               <> concatMany (comment <<|> notFollowedBy (string "*)") *> anyToken <> takeCharsWhile isCommentChar)
               <> string "*)")
   where isCommentChar c = c /= '*' && c /= '('

whiteSpace :: LexicalParsing (Parser g Text) => Parser g Text ()
whiteSpace = spaceChars *> skipMany (lexicalComment *> spaceChars) <?> "whitespace"
   where spaceChars = (takeCharsWhile1 isSpace >>= \ws-> lift ([[WhiteSpace ws]], ())) <<|> pure ()

clearConsumed = tmap clear
   where clear (_, x) = ([], x)

wrapAmbiguous, wrap :: Parser g Text a -> Parser g Text (NodeWrap a)
wrapAmbiguous = wrap
wrap = (Compose <$>) . (\p-> liftA3 surround getSourcePos p getSourcePos)
         . (Compose <$>) . (ambiguous . tmap store) . ((,) (Trailing []) <$>)
   where store (wss, (Trailing [], a)) = (mempty, (Trailing (concat wss), a))
         surround start val end = ((start, end), val)

oberonGrammar, oberon2Grammar, oberonDefinitionGrammar, oberon2DefinitionGrammar
   :: Grammar (OberonGrammar AST.Language NodeWrap) Parser Text
-- | Grammar of an Oberon module
oberonGrammar = fixGrammar grammar
-- | Grammar of an Oberon-2 module
oberon2Grammar = fixGrammar grammar2
-- | Grammar of an Oberon definition module
oberonDefinitionGrammar = fixGrammar definitionGrammar
-- | Grammar of an Oberon-2 definition module
oberon2DefinitionGrammar = fixGrammar definitionGrammar2

grammar, definitionGrammar :: forall l. Abstract.Oberon l
                           => GrammarBuilder (OberonGrammar l NodeWrap) (OberonGrammar l NodeWrap) Parser Text
grammar2, definitionGrammar2 :: forall l. Abstract.Oberon2 l
                             => GrammarBuilder (OberonGrammar l NodeWrap) (OberonGrammar l NodeWrap) Parser Text

definitionGrammar g@OberonGrammar{..} = definitionMixin (grammar g)

definitionGrammar2 g@OberonGrammar{..} = definitionMixin (grammar2 g)

definitionMixin :: Abstract.Oberon l => GrammarBuilder (OberonGrammar l NodeWrap) (OberonGrammar l NodeWrap) Parser Text
definitionMixin g@OberonGrammar{..} = g{
   module_prod = wrap $
                 do lexicalWhiteSpace 
                    keyword "DEFINITION"
                    name <- ident
                    delimiter ";"
                    imports <- moptional importList
                    block <- wrap (Abstract.block <$> declarationSequence <*> pure Nothing)
                    keyword "END"
                    lexicalToken (string name)
                    delimiter "."
                    return (Abstract.moduleUnit name imports block),
   procedureDeclaration = Abstract.procedureDeclaration . snd . sequenceA 
                          <$> wrap procedureHeading 
                          <*> wrap (pure $ Abstract.block [] Nothing),
   identdef = Abstract.exported <$> ident <* optional (delimiter "*")}

grammar2 g@OberonGrammar{..} = g1{
   identdef = ident 
              <**> (Abstract.exported <$ delimiter "*" 
                    <|> Abstract.readOnly <$ delimiter "-" 
                    <|> pure Abstract.identDef),
   
   string_prod = string_prod1 <|> lexicalToken (char '\'' *> takeWhile (/= "'") <* char '\''),
   procedureHeading = procedureHeading1
                      <|> Abstract.typeBoundHeading <$ keyword "PROCEDURE"
                          <* delimiter "("
                          <*> (True <$ keyword "VAR" <|> pure False)
                          <*> ident
                          <* delimiter ":"
                          <*> ident
                          <* delimiter ")"
                          <*> (True <$ delimiter "*" <|> pure False)
                          <**> do n <- clearConsumed (lookAhead ident)
                                  idd <- identdef
                                  params <- optional (wrap formalParameters)
                                  pure (\proc-> (n, proc idd params)),
   arrayType =
      Abstract.arrayType <$ keyword "ARRAY" <*> sepBy length (delimiter ",") <* keyword "OF" <*> wrap type_prod,
   forStatement = 
      Abstract.forStatement <$ keyword "FOR" <*> ident <* delimiter ":=" <*> expression <* keyword "TO" <*> expression
      <*> optional (keyword "BY" *> constExpression) <* keyword "DO"
      <*> wrap statementSequence <* keyword "END",
   withStatement = Abstract.variantWithStatement <$ keyword "WITH"
                      <*> sepByNonEmpty (wrap withAlternative) (delimiter "|")
                      <*> optional (keyword "ELSE" *> wrap statementSequence) <* keyword "END"}
   where g1@OberonGrammar{string_prod= string_prod1, procedureHeading= procedureHeading1} = grammar g
         withAlternative = Abstract.withAlternative <$> qualident <* delimiter ":" <*> qualident
                                                    <*  keyword "DO" <*> wrap statementSequence

grammar OberonGrammar{..} = OberonGrammar{
   module_prod = wrap $
                 do lexicalWhiteSpace
                    keyword "MODULE"
                    name <- ident
                    delimiter ";"
                    imports <- moptional importList
                    body <- wrap (Abstract.block <$> declarationSequence
                                                 <*> optional (wrap (keyword "BEGIN" *> statementSequence)))
                    keyword "END"
                    lexicalToken (string name)
                    delimiter "."
                    return (Abstract.moduleUnit name imports body),
   ident = identifier,
   letter = satisfyCharInput isLetter,
   digit = satisfyCharInput isDigit,
   importList = keyword "IMPORT" *> sepBy1 import_prod (delimiter ",") <* delimiter ";",
   import_prod = Abstract.moduleImport <$> optional (ident <* delimiter ":=") <*> ident,
   declarationSequence = concatMany (((:) <$> wrap (keyword "CONST" *> constantDeclaration)
                                          <*> many (wrap constantDeclaration)
                                      <|> (:) <$> wrap (keyword "TYPE" *> typeDeclaration)
                                              <*> many (wrap typeDeclaration)
                                      <|> (:) <$> wrap (keyword "VAR" *> variableDeclaration)
                                              <*> many (wrap variableDeclaration))
                                     <<|> [] <$ (keyword "CONST" <|> keyword "TYPE" <|> keyword "VAR"))
                         <> many (wrap (procedureDeclaration <* delimiter ";")
                                  <|> wrap (forwardDeclaration <* delimiter ";"))
                         <?> "declarations",
   constantDeclaration = Abstract.constantDeclaration <$> identdef <* delimiter "=" <*> constExpression <* delimiter ";",
   identdef = ident <**> (Abstract.exported <$ delimiter "*" <|> pure Abstract.identDef),
   constExpression = expression,
   expression = simpleExpression
                <|> wrap (flip Abstract.relation <$> simpleExpression <*> relation <*> simpleExpression)
                <|> wrap (Abstract.is <$> simpleExpression <* keyword "IS" <*> qualident)
                <?> "expression",
   simpleExpression = 
      (wrap (Abstract.positive <$ operator "+" <*> term) <|> wrap (Abstract.negative <$ operator "-" <*> term :: Parser (OberonGrammar l NodeWrap) Text (Abstract.Expression l l NodeWrap NodeWrap)) <|> term)
      <**> (appEndo . getDual <$> concatMany (Dual . Endo <$> (flip . applyBinOp <$> addOperator <*> term))),
   term = factor <**> (appEndo . getDual <$> concatMany (Dual . Endo <$> (flip . applyBinOp <$> mulOperator <*> factor))),
   factor = wrapAmbiguous (Abstract.literal <$> wrap (number
                                                      <|> charConstant
                                                      <|> Abstract.string <$> string_prod
                                                      <|> Abstract.nil <$ keyword "NIL")
                           <|> set
                           <|> Abstract.read <$> designator
                           <|> Abstract.functionCall <$> wrapAmbiguous unguardedDesignator <*> actualParameters
                           <|> (Abstract.not <$ operator "~" <*> factor :: Parser (OberonGrammar l NodeWrap) Text (Abstract.Expression l l NodeWrap NodeWrap)))
            <|> parens expression,
   number  =  integer <|> real,
   integer = Abstract.integer . fst . head
             <$> lexicalToken (readDec . unpack <$> takeCharsWhile1 isDigit
                               <|> readHex . unpack <$> (digit <> takeCharsWhile isHexDigit <* string "H")),
   hexDigit = satisfyCharInput isHexDigit,
   real = Abstract.real . fst . head . readFloat . unpack
          <$> lexicalToken (takeCharsWhile1 isDigit <> string "." <> takeCharsWhile isDigit <> moptional scaleFactor),
   scaleFactor = (string "E" <|> "E" <$ string "D") <> moptional (string "+" <|> string "-") <> takeCharsWhile1 isDigit,
   charConstant = lexicalToken (Abstract.charCode . fst . head . readHex . unpack
                                <$> (digit <> takeCharsWhile isHexDigit <* string "X")),
   string_prod = lexicalToken (char '"' *> takeWhile (/= "\"") <* char '"'),
   set = Abstract.set <$> braces (sepBy (wrap element) (delimiter ",")),
   element = Abstract.element <$> expression
             <|> Abstract.range <$> expression <* delimiter ".." <*> expression,
   designator = wrapAmbiguous (unguardedDesignator
                               <|> Abstract.typeGuard <$> designator <*> parens qualident),
   unguardedDesignator = Abstract.variable <$> qualident
                         <|> Abstract.field <$> designator <* delimiter "." <*> ident
                         <|> Abstract.index @l <$> designator <*> brackets expList
                         <|> Abstract.dereference <$> designator <* operator "^",
   expList = sepByNonEmpty expression (delimiter ","),
   actualParameters = parens (sepBy expression (delimiter ",")),
   mulOperator = BinOp . wrapBinary
                 <$> (Abstract.multiply <$ operator "*" <|> Abstract.divide <$ operator "/"
                      <|> Abstract.integerDivide <$ keyword "DIV" <|> Abstract.modulo <$ keyword "MOD" 
                      <|> Abstract.and <$ operator "&"),
   addOperator = BinOp . wrapBinary 
                 <$> (Abstract.add <$ operator "+" <|> Abstract.subtract <$ operator "-" 
                      <|> Abstract.or <$ keyword "OR"),
   relation = Abstract.Equal <$ operator "=" <|> Abstract.Unequal <$ operator "#" 
              <|> Abstract.Less <$ operator "<" <|> Abstract.LessOrEqual <$ operator "<=" 
              <|> Abstract.Greater <$ operator ">" <|> Abstract.GreaterOrEqual <$ operator ">=" 
              <|> Abstract.In <$ keyword "IN",
   typeDeclaration = Abstract.typeDeclaration <$> identdef <* delimiter "=" <*> wrap type_prod <* delimiter ";",
   type_prod = Abstract.typeReference <$> qualident 
               <|> arrayType 
               <|> recordType 
               <|> pointerType
               <|> procedureType,
   qualident = Abstract.qualIdent <$> ident <* delimiter "." <*> ident
               <|> Abstract.nonQualIdent <$> ident,
   arrayType = Abstract.arrayType <$ keyword "ARRAY" <*> sepBy1 length (delimiter ",") <* keyword "OF" <*> wrap type_prod,
   length = constExpression,
   recordType = Abstract.recordType <$ keyword "RECORD" <*> optional (parens baseType)
                <*> fieldListSequence <* keyword "END",
   baseType = qualident,
   fieldListSequence = catMaybes <$> sepBy1 (optional $ wrap fieldList) (delimiter ";"),
   fieldList = Abstract.fieldList <$> identList <* delimiter ":" <*> wrap type_prod <?> "record field declarations",
   identList = sepByNonEmpty identdef (delimiter ","),
   pointerType = Abstract.pointerType <$ keyword "POINTER" <* keyword "TO" <*> wrap type_prod,
   procedureType = Abstract.procedureType <$ keyword "PROCEDURE" <*> optional (wrap formalParameters),
   variableDeclaration = Abstract.variableDeclaration <$> identList <* delimiter ":" <*> wrap type_prod <* delimiter ";",
   procedureDeclaration = do (procedureName, heading) <- sequenceA <$> wrap procedureHeading
                             delimiter ";"
                             body <- wrap procedureBody
                             lexicalToken (string procedureName)
                             return (Abstract.procedureDeclaration heading body),
   procedureHeading = Abstract.procedureHeading <$ keyword "PROCEDURE" <*> (True <$ delimiter "*" <|> pure False)
                      <**> do n <- clearConsumed (lookAhead ident)
                              idd <- identdef
                              params <- optional (wrap formalParameters)
                              return (\proc-> (n, proc idd params)),
   formalParameters = Abstract.formalParameters <$> parens (sepBy (wrap fPSection) (delimiter ";"))
                      <*> optional (delimiter ":" *> qualident),
   fPSection = Abstract.fpSection <$> (True <$ keyword "VAR" <|> pure False) 
               <*> sepBy1 ident (delimiter ",") <* delimiter ":" <*> wrap formalType,
   formalType = Abstract.arrayType [] <$ keyword "ARRAY" <* keyword "OF" <*> wrap formalType 
                <|> Abstract.typeReference <$> qualident
                <|> Abstract.procedureType <$ keyword "PROCEDURE" <*> optional (wrap formalParameters),
   procedureBody = Abstract.block <$> declarationSequence
                   <*> optional (keyword "BEGIN" *> wrap statementSequence) <* keyword "END",
   forwardDeclaration = Abstract.forwardDeclaration <$ keyword "PROCEDURE" <* delimiter "^"
                        <*> identdef <*> optional (wrap formalParameters),
   statementSequence = Abstract.statementSequence <$> sepBy1 statement (delimiter ";"),
   statement = wrapAmbiguous (assignment <|> procedureCall <|> ifStatement <|> caseStatement 
                              <|> whileStatement <|> repeatStatement <|> loopStatement
                              <|> forStatement <|> withStatement 
                              <|> Abstract.exitStatement <$ keyword "EXIT" 
                              <|> Abstract.returnStatement <$ keyword "RETURN" <*> optional expression
                              <|> pure Abstract.emptyStatement)
               <?> "statement",
   assignment  =  Abstract.assignment <$> designator <* delimiter ":=" <*> expression,
   procedureCall = Abstract.procedureCall <$> wrapAmbiguous unguardedDesignator <*> optional actualParameters,
   ifStatement = Abstract.ifStatement <$ keyword "IF"
       <*> sepByNonEmpty (wrap $ Abstract.conditionalBranch <$> expression <* keyword "THEN" <*> wrap statementSequence)
                         (keyword "ELSIF")
       <*> optional (keyword "ELSE" *> wrap statementSequence) <* keyword "END",
   caseStatement = Abstract.caseStatement <$ keyword "CASE" <*> expression
       <*  keyword "OF" <*> (catMaybes <$> sepBy1 (optional $ wrap case_prod) (delimiter "|"))
       <*> optional (keyword "ELSE" *> wrap statementSequence) <* keyword "END",
   case_prod = Abstract.caseAlternative <$> caseLabelList <* delimiter ":" <*> wrap statementSequence,
   caseLabelList = sepByNonEmpty (wrap caseLabels) (delimiter ","),
   caseLabels = Abstract.singleLabel <$> constExpression
                <|> Abstract.labelRange <$> constExpression <* delimiter ".." <*> constExpression,
   whileStatement = Abstract.whileStatement <$ keyword "WHILE" <*> expression <* keyword "DO"
                    <*> wrap statementSequence <* keyword "END",
   repeatStatement = Abstract.repeatStatement <$ keyword "REPEAT"
                     <*> wrap statementSequence <* keyword "UNTIL" <*> expression,
   loopStatement = Abstract.loopStatement <$ keyword "LOOP" <*> wrap statementSequence <* keyword "END",
   forStatement = empty,
   withStatement = Abstract.withStatement <$ keyword "WITH"
                   <*> wrap (Abstract.withAlternative <$> qualident <* delimiter ":" <*> qualident
                             <* keyword "DO" <*> wrap statementSequence)
                   <* keyword "END"}

wrapBinary :: (NodeWrap a -> NodeWrap a -> a) -> (NodeWrap a -> NodeWrap a -> NodeWrap a)
wrapBinary op a@(Compose (pos, _)) b = Compose (pos, Compose $ pure (Trailing [], op a b))

moptional :: (Alternative f, Monoid (f a)) => f a -> f a
moptional p = p <|> mempty

delimiter, operator :: Abstract.Oberon l => Text -> Parser (OberonGrammar l f) Text Text

delimiter s = lexicalToken (string s <* lift ([[Token Delimiter s]], ())) <?> ("delimiter " <> show s)
operator s = lexicalToken (string s <* lift ([[Token Operator s]], ())) <?> ("operator " <> show s)

reservedWords :: [Text]
reservedWords = ["ARRAY", "IMPORT", "RETURN",
                 "BEGIN", "IN", "THEN",
                 "BY", "IS", "TO",
                 "CASE", "LOOP", "TYPE",
                 "DIV", "MODULE", "VAR",
                 "DO", "NIL", "WHILE",
                 "ELSE", "OF", "WITH",
                 "ELSIF", "OR",
                 "END", "POINTER",
                 "EXIT", "PROCEDURE",
                 "FOR", "RECORD",
                 "IF", "REPEAT"]

{-
https://cseweb.ucsd.edu/~wgg/CSE131B/oberon2.htm

Module       = MODULE ident ";" [ImportList] DeclSeq
               [BEGIN StatementSeq] END ident ".".
ImportList   = IMPORT [ident ":="] ident {"," [ident ":="] ident} ";".
DeclSeq      = { CONST {ConstDecl ";" } | TYPE {TypeDecl ";"}
                 | VAR {VarDecl ";"}} {ProcDecl ";" | ForwardDecl ";"}.
ConstDecl    = IdentDef "=" ConstExpr.
TypeDecl     = IdentDef "=" Type.
VarDecl      = IdentList ":" Type.
ProcDecl     = PROCEDURE [Receiver] IdentDef [FormalPars] ";" DeclSeq
               [BEGIN StatementSeq] END ident.
ForwardDecl  = PROCEDURE "^" [Receiver] IdentDef [FormalPars].
FormalPars   = "(" [FPSection {";" FPSection}] ")" [":" Qualident].
FPSection    = [VAR] ident {"," ident} ":" Type.
Receiver     = "(" [VAR] ident ":" ident ")".
Type         = Qualident
             | ARRAY [ConstExpr {"," ConstExpr}] OF Type
             | RECORD ["("Qualident")"] FieldList {";" FieldList} END
             | POINTER TO Type
             | PROCEDURE [FormalPars].
FieldList    = [IdentList ":" Type].
StatementSeq = Statement {";" Statement}.
Statement    = [ Designator ":=" Expr 
             | Designator ["(" [ExprList] ")"] 
             | IF Expr THEN StatementSeq {ELSIF Expr THEN StatementSeq}
               [ELSE StatementSeq] END 
             | CASE Expr OF Case {"|" Case} [ELSE StatementSeq] END 
             | WHILE Expr DO StatementSeq END 
             | REPEAT StatementSeq UNTIL Expr 
             | FOR ident ":=" Expr TO Expr [BY ConstExpr] DO StatementSeq END 
             | LOOP StatementSeq END
             | WITH Guard DO StatementSeq {"|" Guard DO StatementSeq}
               [ELSE StatementSeq] END
             | EXIT 
             | RETURN [Expr]
             ].
Case         = [CaseLabels {"," CaseLabels} ":" StatementSeq].
CaseLabels   = ConstExpr [".." ConstExpr].
Guard        = Qualident ":" Qualident.
ConstExpr    = Expr.
Expr         = SimpleExpr [Relation SimpleExpr].
SimpleExpr   = ["+" | "-"] Term {AddOp Term}.
Term         = Factor {MulOp Factor}.
Factor       = Designator ["(" [ExprList] ")"] | number | character | string
               | NIL | Set | "(" Expr ")" | " ~ " Factor.
Set          = "{" [Element {"," Element}] "}".
Element      = Expr [".." Expr].
Relation     = "=" | "#" | "<" | "<=" | ">" | ">=" | IN | IS.
AddOp        = "+" | "-" | OR.
MulOp        = " * " | "/" | DIV | MOD | "&".
Designator   = Qualident {"." ident | "[" ExprList "]" | " ^ "
               | "(" Qualident ")"}.
ExprList     = Expr {"," Expr}.
IdentList    = IdentDef {"," IdentDef}.
Qualident    = [ident "."] ident.
IdentDef     = ident [" * " | "-"].
-}

{-
EBNF definition of a Module Definition ( .Def)

A module definition follows the Oberon grammar. The only differences are in the productions:

module  =  DEFINITION ident ";"  [ImportList] DeclarationSequence END ident ".".

where the body is removed and in:

ProcedureDeclaration  = ProcedureHeading ";"

where ProcedureBody and ident are removed. All the productions from ProcedureBody may be ignored. Depending on the tool (Watson or Browser), the export marks may or may not be included in the output.

12 Jul 2002 - Copyright © 2002 ETH Zürich. All rights reserved.
E-Mail: oberon-web at inf.ethz.ch
Homepage: www.ethoberon.ethz.ch {http://www.ethoberon.ethz.ch/}
-}

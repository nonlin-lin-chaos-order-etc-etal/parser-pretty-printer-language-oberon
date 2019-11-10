{-# LANGUAGE DeriveDataTypeable, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances,
             OverloadedStrings, StandaloneDeriving, TemplateHaskell, TypeFamilies #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

-- | Oberon Abstract Syntax Tree definitions

module Language.Oberon.AST (module Language.Oberon.AST, RelOp(..)) where

import Control.Monad (forM, mapM)
import Control.Applicative (ZipList(ZipList, getZipList))
import Data.Data (Data, Typeable)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)

import qualified Transformation
import qualified Transformation.Shallow as Shallow
import qualified Transformation.Shallow.TH
import qualified Transformation.Deep.TH
import qualified Transformation.AG as AG
import qualified Rank2.TH

import qualified Language.Oberon.Abstract as Abstract
import Language.Oberon.Abstract (RelOp(..))

-- | Orphan instance
deriving instance Data a => Data (ZipList a)

data Language = Language deriving (Data, Typeable)

instance Abstract.Wirthy Language where
   type Module Language = Module Language
   type Declaration Language = Declaration Language
   type Type Language = Type Language
   type Statement Language = Statement Language
   type Expression Language = Expression Language
   type Designator Language = Designator Language
   type Value Language = Value Language

   type Import Language = Import Language
   type FieldList Language = FieldList Language
   type ProcedureHeading Language = ProcedureHeading Language
   type FormalParameters Language = FormalParameters Language
   type FPSection Language = FPSection Language
   type Block Language = Block Language
   type StatementSequence Language = StatementSequence Language
   type Case Language = Case Language
   type CaseLabels Language = CaseLabels Language
   type ConditionalBranch Language = ConditionalBranch Language
   type Element Language = Element Language

   type IdentDef Language = IdentDef Language
   type QualIdent Language = QualIdent Language

   -- Declaration
   constantDeclaration = ConstantDeclaration
   typeDeclaration = TypeDeclaration
   variableDeclaration = VariableDeclaration
   procedureDeclaration = ProcedureDeclaration

   formalParameters = FormalParameters . ZipList
   fpSection = FPSection
   block = Block . ZipList
   
   fieldList = FieldList

   -- Type
   pointerType = PointerType
   procedureType = ProcedureType
   typeReference = TypeReference

   -- Statement
   assignment = Assignment
   caseStatement scrutinee cases = CaseStatement scrutinee (ZipList cases)
   emptyStatement = EmptyStatement
   exitStatement = Exit
   ifStatement (branch :| branches) = If branch (ZipList branches)
   loopStatement = Loop
   procedureCall proc args = ProcedureCall proc (ZipList <$> args)
   repeatStatement = Repeat
   returnStatement = Return
   whileStatement = While

   conditionalBranch = ConditionalBranch
   caseAlternative (c :| cs) = Case c (ZipList cs)
   labelRange = LabelRange
   singleLabel = SingleLabel
   
   statementSequence = StatementSequence . ZipList

   -- Expression
   add = Add
   and = And
   divide = Divide
   functionCall fun args = FunctionCall fun (ZipList args)
   integerDivide = IntegerDivide
   literal = Literal
   modulo = Modulo
   multiply = Multiply
   negative = Negative
   not = Not
   or = Or
   positive = Positive
   read = Read
   relation = Relation
   subtract = Subtract

   element = Element
   range = Range

   -- Value
   builtin = Builtin
   charCode = CharCode
   false = Boolean False
   integer = Integer
   nil = Nil
   real = Real
   string = String
   true = Boolean True

   -- Designator
   variable = Variable
   field = Field
   index array (i :| is) = Index array i (ZipList is)
   dereference = Dereference

   -- Identifier
   identDef = flip IdentDef PrivateOnly
   nonQualIdent = NonQualIdent

instance Abstract.CoWirthy Language where
   coDeclaration (ConstantDeclaration name value) = Just (Abstract.constantDeclaration name value)
   coDeclaration (TypeDeclaration name ty) = Just (Abstract.typeDeclaration name ty)
   coDeclaration (VariableDeclaration name ty) = Just (Abstract.variableDeclaration name ty)
--   coDeclaration (ProcedureDeclaration name ty) = Abstract.procedureDeclaration <$> Abstract.coIdentDef name <*> traverse Abstract.coType ty
   coDeclaration (ProcedureDeclaration name ty) = Nothing
   coDeclaration ForwardDeclaration{} = Nothing
   
--   coType (TypeReference q) = Just (Abstract.typeReference q)
--   coType (ProcedureType params) = Just (Abstract.procedureType params)
   coType (PointerType destination) = Just (Abstract.pointerType destination)
   coType _ = Nothing
   
   coStatement EmptyStatement = Just Abstract.emptyStatement
   coStatement (Assignment destination expression) = Just (Abstract.assignment destination expression)
   coStatement (ProcedureCall procedure parameters) = Just (Abstract.procedureCall procedure $ getZipList <$> parameters)
   coStatement (If branch elsifs fallback) = Just (Abstract.ifStatement (branch :| getZipList elsifs) fallback)
--   coStatement (CaseStatement scrutinee cases fallback) = Just (Abstract.caseStatement scrutinee cases fallback)
   coStatement (CaseStatement scrutinee cases fallback) = Nothing
   coStatement (While condition body) = Just (Abstract.whileStatement condition body)
   coStatement (Repeat body condition) = Just (Abstract.repeatStatement body condition)
   coStatement (For _index _from _to _by _body) = Nothing
   coStatement (Loop body) = Just (Abstract.loopStatement body)
   coStatement (With _alternative _alternatives _fallback) = Nothing
   coStatement Exit = Just Abstract.exitStatement
   coStatement (Return result) = Just (Abstract.returnStatement result)
   
   coExpression (Relation op left right) = Just (Abstract.relation op left right)
   coExpression (IsA _left _right) = Nothing
   coExpression (Positive e) = Just (Abstract.positive e)
   coExpression (Negative e) = Just (Abstract.negative e)
   coExpression (Add left right) = Just (Abstract.add left right)
   coExpression (Subtract left right) = Just (Abstract.subtract left right)
   coExpression (Or left right) = Just (Abstract.or left right)
   coExpression (Multiply left right) = Just (Abstract.multiply left right)
   coExpression (Divide left right) = Just (Abstract.divide left right)
   coExpression (IntegerDivide left right) = Just (Abstract.integerDivide left right)
   coExpression (Modulo left right) = Just (Abstract.modulo left right)
   coExpression (And left right) = Just (Abstract.and left right)
   coExpression (Set _elements) = Nothing
   coExpression (Read var) = Just (Abstract.read var)
   coExpression (FunctionCall function parameters) = Just (Abstract.functionCall function $ getZipList parameters)
   coExpression (Not e) = Just (Abstract.not e)

   coValue Nil = Just Abstract.nil
   coValue (Boolean False) = Just Abstract.false
   coValue (Boolean True) = Just Abstract.true
   coValue (Builtin name) = Just (Abstract.builtin name)
   coValue (Integer n) = Just (Abstract.integer n)
   coValue (Real r) = Just (Abstract.real r)
   coValue (String s) = Just (Abstract.string s)
   coValue (CharCode c) = Just (Abstract.charCode c)
   
   coDesignator (Variable q) = Just (Abstract.variable q)
   coDesignator (Field record name) = Just (Abstract.field record name)
   coDesignator (Index array index indexes) = Just (Abstract.index array (index :| getZipList indexes))
   coDesignator (TypeGuard _scrutinee _typeName) = Nothing
   coDesignator (Dereference pointer) = Just (Abstract.dereference pointer)

instance Abstract.Nameable Language where
   getProcedureName (ProcedureHeading _ iddef _) = Abstract.getIdentDefName iddef
   getProcedureName (TypeBoundHeading _ _ _ _ iddef _) = Abstract.getIdentDefName iddef
   getIdentDefName (IdentDef name _) = name
   getNonQualIdentName (NonQualIdent name) = Just name
   getNonQualIdentName _ = Nothing

isNamedVar :: Abstract.Nameable l => Ident -> Maybe (Designator Language l f f) -> Bool
isNamedVar name (Just (Variable q)) | Abstract.getNonQualIdentName q == Just name = True
isNamedVar _ _ = False

instance Abstract.Oberon Language where
   type WithAlternative Language = WithAlternative Language
   moduleUnit name imports declarations = Module name imports (ZipList declarations)
   moduleImport = (,)
   exported = flip IdentDef Exported
   qualIdent = QualIdent
   getQualIdentNames (QualIdent moduleName name) = Just (moduleName, name)
   getQualIdentNames _ = Nothing

   arrayType = ArrayType . ZipList
   recordType base fields = RecordType base (ZipList fields)
   procedureHeading = ProcedureHeading
   forwardDeclaration = ForwardDeclaration
   withStatement alt = With alt (ZipList []) Nothing
   withAlternative = WithAlternative
   is = IsA
   set = Set . ZipList
   typeGuard = TypeGuard

instance Abstract.Oberon2 Language where
   readOnly = flip IdentDef ReadOnly
   typeBoundHeading = TypeBoundHeading
   forStatement = For
   variantWithStatement (variant :| variants) = With variant (ZipList variants)

data Module λ l f' f =
   Module Ident [Import l] (ZipList (f (Abstract.Declaration l l f' f'))) (Maybe (f (Abstract.StatementSequence l l f' f')))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.Import l),
                   Data (f (Abstract.Declaration l l f' f')), Data (f (Abstract.StatementSequence l l f' f'))) =>
                  Data (Module λ l f' f)
deriving instance (Show (Abstract.Import l), Show (f (Abstract.Declaration l l f' f')),
                   Show (f (Abstract.StatementSequence l l f' f'))) =>
                  Show (Module λ l f' f)

type Ident = Text

type Import l = (Maybe Ident, Ident)

data Declaration λ l f' f = ConstantDeclaration (Abstract.IdentDef l) (f (Abstract.ConstExpression l l f' f'))
                          | TypeDeclaration (Abstract.IdentDef l) (f (Abstract.Type l l f' f'))
                          | VariableDeclaration (Abstract.IdentList l) (f (Abstract.Type l l f' f'))
                          | ProcedureDeclaration (f (Abstract.ProcedureHeading l l f' f'))
                                                 (f (Abstract.Block l l f' f'))
                          | ForwardDeclaration (Abstract.IdentDef l) (Maybe (f (Abstract.FormalParameters l l f' f')))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f',
                   Data (f (Abstract.Type l l f' f')), Data (f (Abstract.ConstExpression l l f' f')),
                   Data (f (Abstract.FormalParameters l l f' f')), Data (f (Abstract.ProcedureHeading l l f' f')),
                   Data (f (Abstract.Block l l f' f')), Data (Abstract.IdentDef l)) => Data (Declaration λ l f' f)
deriving instance (Show (f (Abstract.Type l l f' f')), Show (f (Abstract.ConstExpression l l f' f')),
                   Show (f (Abstract.FormalParameters l l f' f')), Show (f (Abstract.ProcedureHeading l l f' f')),
                   Show (f (Abstract.Block l l f' f')), Show (Abstract.IdentDef l)) => Show (Declaration λ l f' f)

data QualIdent l = QualIdent Ident Ident 
                 | NonQualIdent Ident
   deriving (Data, Eq, Ord, Show)

data IdentDef l = IdentDef Ident AccessMode
   deriving (Data, Eq, Ord, Show)

data AccessMode = Exported | ReadOnly | PrivateOnly
   deriving (Data, Eq, Ord, Show)

data Expression λ l f' f = Relation RelOp (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | IsA (f (Abstract.Expression l l f' f')) (Abstract.QualIdent l)
                         | Positive (f (Abstract.Expression l l f' f'))
                         | Negative (f (Abstract.Expression l l f' f'))
                         | Add (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | Subtract (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | Or (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | Multiply (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | Divide (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | IntegerDivide (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | Modulo (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | And (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))
                         | Set (ZipList (f (Abstract.Element l l f' f')))
                         | Read (f (Abstract.Designator l l f' f'))
                         | FunctionCall (f (Abstract.Designator l l f' f')) (ZipList (f (Abstract.Expression l l f' f')))
                         | Not (f (Abstract.Expression l l f' f'))
                         | Literal (f (Abstract.Value l l f' f'))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f',
                   Data (Abstract.QualIdent l), Data (f (Abstract.Value l l f' f')),
                   Data (f (Abstract.Designator l l f' f')), Data (f (Abstract.Element l l f' f')),
                   Data (f (Abstract.Expression l l f' f'))) =>
                  Data (Expression λ l f' f)
deriving instance (Show (Abstract.QualIdent l), Show (f (Abstract.Value l l f' f')), Show (f (Abstract.Designator l l f' f')),
                   Show (f (Abstract.Element l l f' f')), Show (f (Abstract.Expression l l f' f'))) =>
                  Show (Expression λ l f' f)
deriving instance (Eq (Abstract.QualIdent l), Eq (f (Abstract.Value l l f' f')),
                   Eq (f (Abstract.Designator l l f' f')), Eq (f (Abstract.Element l l f' f')),
                   Eq (f (Abstract.Expression l l f' f'))) => Eq (Expression λ l f' f)

data Element λ l f' f = Element (f (Abstract.Expression l l f' f'))
                      | Range (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f'))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (f (Abstract.Expression l l f' f'))) =>
                  Data (Element λ l f' f)
deriving instance Show (f (Abstract.Expression l l f' f')) => Show (Element λ l f' f)
deriving instance Eq (f (Abstract.Expression l l f' f')) => Eq (Element λ l f' f)

data Value λ l (f' :: * -> *) (f :: * -> *) = Boolean Bool
                                            | Builtin Text
                                            | CharCode Int
                                            | Integer Integer
                                            | Nil
                                            | Real Double
                                            | String Text
                                            deriving (Eq, Show)

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f') => Data (Value λ l f' f)

data Designator λ l f' f = Variable (Abstract.QualIdent l)
                         | Field (f (Abstract.Designator l l f' f')) Ident 
                         | Index (f (Abstract.Designator l l f' f'))
                                 (f (Abstract.Expression l l f' f')) (ZipList (f (Abstract.Expression l l f' f')))
                         | TypeGuard (f (Abstract.Designator l l f' f')) (Abstract.QualIdent l)
                         | Dereference (f (Abstract.Designator l l f' f'))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.QualIdent l),
                   Data (f (Abstract.Designator l l f' f')), Data (f (Abstract.Expression l l f' f'))) =>
                  Data (Designator λ l f' f)
deriving instance (Show (Abstract.QualIdent l), Show (f (Abstract.Designator l l f' f')),
                   Show (f (Abstract.Expression l l f' f'))) => Show (Designator λ l f' f)
deriving instance (Eq (Abstract.QualIdent l), Eq (f (Abstract.Designator l l f' f')),
                   Eq (f (Abstract.Expression l l f' f'))) => Eq (Designator λ l f' f)

data Type λ l f' f = TypeReference (Abstract.QualIdent l)
                   | ArrayType (ZipList (f (Abstract.ConstExpression l l f' f'))) (f (Abstract.Type l l f' f'))
                   | RecordType (Maybe (Abstract.BaseType l)) (ZipList (f (Abstract.FieldList l l f' f')))
                   | PointerType (f (Abstract.Type l l f' f'))
                   | ProcedureType (Maybe (f (Abstract.FormalParameters l l f' f')))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.QualIdent l), Data (f (Abstract.Type l l f' f')),
                   Data (f (Abstract.ConstExpression l l f' f')), Data (f (Abstract.FormalParameters l l f' f')),
                   Data (f (Abstract.FieldList l l f' f'))) =>
                  Data (Type λ l f' f)
deriving instance (Show (Abstract.QualIdent l), Show (f (Abstract.Type l l f' f')),
                   Show (f (Abstract.ConstExpression l l f' f')), Show (f (Abstract.FormalParameters l l f' f')),
                   Show (f (Abstract.FieldList l l f' f'))) =>
                  Show (Type λ l f' f)

data FieldList λ l f' f = FieldList (Abstract.IdentList l) (f (Abstract.Type l l f' f'))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.IdentDef l), Data (f (Abstract.Type l l f' f')),
                   Data (f (Abstract.Expression l l f' f'))) => Data (FieldList λ l f' f)
deriving instance (Show (Abstract.IdentDef l), Show (f (Abstract.Type l l f' f')), Show (f (Abstract.Expression l l f' f'))) =>
                  Show (FieldList λ l f' f)

data ProcedureHeading λ l f' f =
   ProcedureHeading                    Bool (Abstract.IdentDef l) (Maybe (f (Abstract.FormalParameters l l f' f')))
   | TypeBoundHeading Bool Ident Ident Bool (Abstract.IdentDef l) (Maybe (f (Abstract.FormalParameters l l f' f')))

data FormalParameters λ l f' f = FormalParameters (ZipList (f (Abstract.FPSection l l f' f'))) (Maybe (Abstract.ReturnType l))

data FPSection λ l f' f = FPSection Bool [Ident] (f (Abstract.Type l l f' f'))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.IdentDef l),
                   Data (f (Abstract.FormalParameters l l f' f'))) => Data (ProcedureHeading λ l f' f)
deriving instance (Show (Abstract.IdentDef l), Show (f (Abstract.FormalParameters l l f' f'))) =>
                  Show (ProcedureHeading λ l f' f)

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.ReturnType l),
                   Data (f (Abstract.FPSection l l f' f')),  Data (f (Abstract.Expression l l f' f'))) =>
                  Data (FormalParameters λ l f' f)
deriving instance (Show (f (Abstract.FPSection l l f' f')), Show (Abstract.ReturnType l),
                   Show (f (Abstract.Expression l l f' f'))) => Show (FormalParameters λ l f' f)

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (f (Abstract.Type l l f' f')),
                   Data (f (Abstract.Expression l l f' f'))) => Data (FPSection λ l f' f)
deriving instance (Show (f (Abstract.Type l l f' f')), Show (f (Abstract.Expression l l f' f'))) => Show (FPSection λ l f' f)

data Block λ l f' f = Block (ZipList (f (Abstract.Declaration l l f' f'))) (Maybe (f (Abstract.StatementSequence l l f' f')))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (f (Abstract.Declaration l l f' f')),
                   Data (f (Abstract.Designator l l f' f')), Data (f (Abstract.Expression l l f' f')),
                   Data (f (Abstract.StatementSequence l l f' f'))) =>
                  Data (Block λ l f' f)
deriving instance (Show (f (Abstract.Declaration l l f' f')), Show (f (Abstract.Designator l l f' f')),
                   Show (f (Abstract.Expression l l f' f')), Show (f (Abstract.StatementSequence l l f' f'))) =>
                  Show (Block λ l f' f)

newtype StatementSequence λ l f' f = StatementSequence (ZipList (f (Abstract.Statement l l f' f')))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (f (Abstract.Statement l l f' f'))) =>
                  Data (StatementSequence λ l f' f)
deriving instance Show (f (Abstract.Statement l l f' f')) => Show (StatementSequence λ l f' f)

data Statement λ l f' f = EmptyStatement
                        | Assignment (f (Abstract.Designator l l f' f')) (f (Abstract.Expression l l f' f'))
                        | ProcedureCall (f (Abstract.Designator l l f' f')) (Maybe (ZipList (f (Abstract.Expression l l f' f'))))
                        | If (f (Abstract.ConditionalBranch l l f' f'))
                             (ZipList (f (Abstract.ConditionalBranch l l f' f')))
                             (Maybe (f (Abstract.StatementSequence l l f' f')))
                        | CaseStatement (f (Abstract.Expression l l f' f')) 
                                        (ZipList (f (Abstract.Case l l f' f')))
                                        (Maybe (f (Abstract.StatementSequence l l f' f')))
                        | While (f (Abstract.Expression l l f' f')) (f (Abstract.StatementSequence l l f' f'))
                        | Repeat (f (Abstract.StatementSequence l l f' f')) (f (Abstract.Expression l l f' f'))
                        | For Ident (f (Abstract.Expression l l f' f')) (f (Abstract.Expression l l f' f')) 
                              (Maybe (f (Abstract.Expression l l f' f'))) (f (Abstract.StatementSequence l l f' f'))  -- Oberon2
                        | Loop (f (Abstract.StatementSequence l l f' f'))
                        | With (f (Abstract.WithAlternative l l f' f'))
                               (ZipList (f (Abstract.WithAlternative l l f' f')))
                               (Maybe (f (Abstract.StatementSequence l l f' f')))
                        | Exit
                        | Return (Maybe (f (Abstract.Expression l l f' f')))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f',
                   Data (f (Abstract.Designator l l f' f')), Data (f (Abstract.Expression l l f' f')),
                   Data (f (Abstract.Case l l f' f')), Data (f (Abstract.WithAlternative l l f' f')),
                   Data (f (Abstract.ConditionalBranch l l f' f')),
                   Data (f (Abstract.StatementSequence l l f' f'))) => Data (Statement λ l f' f)
deriving instance (Show (f (Abstract.Designator l l f' f')), Show (f (Abstract.Expression l l f' f')),
                   Show (f (Abstract.Case l l f' f')), Show (f (Abstract.WithAlternative l l f' f')),
                   Show (f (Abstract.ConditionalBranch l l f' f')),
                   Show (f (Abstract.StatementSequence l l f' f'))) => Show (Statement λ l f' f)

data WithAlternative λ l f' f = WithAlternative (Abstract.QualIdent l) (Abstract.QualIdent l)
                                                (f (Abstract.StatementSequence l l f' f'))

data Case λ l f' f = Case (f (Abstract.CaseLabels l l f' f')) (ZipList (f (Abstract.CaseLabels l l f' f')))
                          (f (Abstract.StatementSequence l l f' f'))

data CaseLabels λ l f' f = SingleLabel (f (Abstract.ConstExpression l l f' f'))
                         | LabelRange (f (Abstract.ConstExpression l l f' f')) (f (Abstract.ConstExpression l l f' f'))

data ConditionalBranch λ l f' f =
   ConditionalBranch (f (Abstract.Expression l l f' f')) (f (Abstract.StatementSequence l l f' f'))

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (Abstract.QualIdent l),
                   Data (f (Abstract.Designator l l f' f')), Data (f (Abstract.StatementSequence l l f' f'))) =>
                  Data (WithAlternative λ l f' f)
deriving instance (Show (Abstract.QualIdent l), Show (f (Abstract.StatementSequence l l f' f'))) =>
                  Show (WithAlternative λ l f' f)

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f',
                   Data (f (Abstract.CaseLabels l l f' f')), Data (f (Abstract.StatementSequence l l f' f'))) =>
                  Data (Case λ l f' f)
deriving instance (Show (f (Abstract.CaseLabels l l f' f')), Show (f (Abstract.StatementSequence l l f' f'))) =>
                  Show (Case λ l f' f)

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f',
                   Data (f (Abstract.Expression l l f' f')), Data (f (Abstract.StatementSequence l l f' f'))) =>
                  Data (ConditionalBranch λ l f' f)
deriving instance (Show (f (Abstract.Expression l l f' f')), Show (f (Abstract.StatementSequence l l f' f'))) =>
                  Show (ConditionalBranch λ l f' f)

deriving instance (Typeable λ, Typeable l, Typeable f, Typeable f', Data (f (Abstract.ConstExpression l l f' f'))) =>
                  Data (CaseLabels λ l f' f)
deriving instance Show (f (Abstract.ConstExpression l l f' f')) => Show (CaseLabels λ l f' f)

$(concat <$>
  (forM [Rank2.TH.deriveFunctor, Rank2.TH.deriveFoldable, Rank2.TH.deriveTraversable,
         Transformation.Shallow.TH.deriveAll, Transformation.Deep.TH.deriveAll] $
   \derive-> mconcat <$> mapM derive
             [''Module, ''Declaration, ''Type, ''Expression, ''Value,
              ''Element, ''Designator, ''FieldList,
              ''ProcedureHeading, ''FormalParameters, ''FPSection, ''Block,
              ''Statement, ''StatementSequence,
              ''Case, ''CaseLabels, ''ConditionalBranch, ''WithAlternative]))

$(mconcat <$> mapM Rank2.TH.unsafeDeriveApply
  [''Declaration, ''Type, ''Expression, ''Value,
   ''Element, ''Designator, ''FieldList,
   ''ProcedureHeading, ''FormalParameters, ''FPSection, ''Block,
   ''Statement, ''StatementSequence,
   ''Case, ''CaseLabels, ''ConditionalBranch, ''WithAlternative])

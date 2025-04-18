{-# LANGUAGE DataKinds, DeriveGeneric, DuplicateRecordFields, FlexibleContexts, FlexibleInstances,
             MultiParamTypeClasses, NamedFieldPuns, OverloadedStrings, ScopedTypeVariables, StandaloneDeriving,
             TypeFamilies, TypeOperators, UndecidableInstances, ViewPatterns #-}

-- | Type checker for Oberon AST. The AST must have its ambiguities previously resolved by "Language.Oberon.Resolver".
module Language.Oberon.TypeChecker (checkModules, errorMessage, Error(..), ErrorType(..), predefined, predefined2) where

import Control.Applicative (liftA2, (<|>), ZipList(ZipList, getZipList))
import Control.Arrow (first)
import Data.Coerce (coerce)
import Data.Proxy (Proxy(..))
import qualified Data.List as List
import Data.Functor.Const (Const(..))
import Data.Maybe (fromMaybe)
import Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as Map
import Data.Semigroup (Semigroup(..))
import qualified Data.Text as Text
import GHC.Generics (Generic)

import qualified Rank2
import qualified Transformation
import qualified Transformation.Shallow as Shallow
import qualified Transformation.Deep as Deep
import qualified Transformation.Full as Full
import qualified Transformation.Full.TH
import qualified Transformation.AG as AG
import qualified Transformation.AG.Generics as AG
import Transformation.AG (Attribution(..), Atts, Inherited(..), Synthesized(..), Semantics)
import Transformation.AG.Generics (Auto(Auto), Folded(..), Bequether(..), Synthesizer(..), SynthesizedField)

import qualified Language.Oberon.Abstract as Abstract
import qualified Language.Oberon.AST as AST
import Language.Oberon.Grammar (ParsedLexemes(Trailing))
import Language.Oberon.Resolver (Placed)

data Type l = NominalType (Abstract.QualIdent l) (Maybe (Type l))
            | RecordType{ancestry :: [Abstract.QualIdent l],
                         recordFields :: Map AST.Ident (Type l)}
            | NilType
            | IntegerType Int
            | StringType Int
            | ArrayType [Int] (Type l)
            | PointerType (Type l)
            | ReceiverType (Type l)
            | ProcedureType Bool [(Bool, Type l)] (Maybe (Type l))
            | BuiltinType Text.Text
            | UnknownType

data ErrorType l = ArgumentCountMismatch Int Int
                 | ExtraDimensionalIndex Int Int
                 | IncomparableTypes (Type l) (Type l)
                 | IncompatibleTypes (Type l) (Type l)
                 | TooSmallArrayType Int Int
                 | OpenArrayVariable
                 | NonArrayType (Type l)
                 | NonBooleanType (Type l)
                 | NonFunctionType (Type l)
                 | NonIntegerType (Type l)
                 | NonNumericType (Type l)
                 | NonPointerType (Type l)
                 | NonProcedureType (Type l)
                 | NonRecordType (Type l)
                 | TypeMismatch (Type l) (Type l)
                 | UnequalTypes (Type l) (Type l)
                 | UnrealType (Type l)
                 | UnknownName (Abstract.QualIdent l)
                 | UnknownField AST.Ident (Type l)

data Error m l = Error{errorModule   :: m,
                       errorPosition :: LexicalPosition,
                       errorType     :: ErrorType l}

type LexicalPosition = (Int, ParsedLexemes, Int)

instance Eq (Abstract.QualIdent l) => Eq (Type l) where
  NominalType q1 (Just t1) == t2@(NominalType q2 _) = q1 == q2 || t1 == t2
  t1@(NominalType q1 _) == NominalType q2 (Just t2) = q1 == q2 || t1 == t2
  NominalType q1 Nothing == NominalType q2 Nothing = q1 == q2
  ArrayType [] t1 == ArrayType [] t2 = t1 == t2
  ProcedureType _ p1 r1 == ProcedureType _ p2 r2 = r1 == r2 && p1 == p2
  StringType len1 == StringType len2 = len1 == len2
  NilType == NilType = True
  BuiltinType name1 == BuiltinType name2 = name1 == name2
  ReceiverType t1 == t2 = t1 == t2
  t1 == ReceiverType t2 = t1 == t2
  _ == _ = False

deriving instance Show (Abstract.QualIdent l) => Show (Type l)

deriving instance Eq (Abstract.QualIdent l) => Eq (ErrorType l)
deriving instance Show (Abstract.QualIdent l) => Show (ErrorType l)

deriving instance (Eq m, Eq (Abstract.QualIdent l)) => Eq (Error m l)
deriving instance (Show m, Show (Abstract.QualIdent l)) => Show (Error m l)

errorMessage :: (Abstract.Nameable l, Abstract.Oberon l, Show (Abstract.QualIdent l)) => ErrorType l -> String
errorMessage (ArgumentCountMismatch expected actual) =
   "Expected " <> show expected <> ", received " <> show actual <> " arguments"
errorMessage (ExtraDimensionalIndex expected actual) =
   "Expected " <> show expected <> ", received " <> show actual <> " indexes"
errorMessage (IncomparableTypes left right) = 
   "Values of types " <> typeMessage left <> " and " <> typeMessage right <> " cannot be compared"
errorMessage (IncompatibleTypes left right) =
   "Incompatible types " <> typeMessage left <> " and " <> typeMessage right
errorMessage (TooSmallArrayType expected actual) = 
   "The array of length " <> show expected <> " cannot contain " <> show actual <> " items"
errorMessage OpenArrayVariable = "A variable cannot be declared an open array"
errorMessage (NonArrayType t) = "Trying to index a non-array type " <> typeMessage t
errorMessage (NonBooleanType t) = "Type " <> typeMessage t <> " is not Boolean"
errorMessage (NonFunctionType t) = "Trying to invoke a " <> typeMessage t <> " as a function"
errorMessage (NonIntegerType t) = "Type " <> typeMessage t <> " is not an integer type"
errorMessage (NonNumericType t) = "Type " <> typeMessage t <> " is not a numeric type"
errorMessage (NonPointerType t) = "Trying to dereference a non-pointer type " <> typeMessage t
errorMessage (NonProcedureType t) = "Trying to invoke a " <> typeMessage t <> " as a procedure"
errorMessage (NonRecordType t) = "Non-record type " <> typeMessage t
errorMessage (TypeMismatch t1 t2) = "Type mismatch between " <> typeMessage t1 <> " and " <> typeMessage t2
errorMessage (UnequalTypes t1 t2) = "Unequal types " <> typeMessage t1 <> " and " <> typeMessage t2
errorMessage (UnrealType t) = "Type " <> typeMessage t <> " is not a numeric real type"
errorMessage (UnknownName q) = "Unknown name " <> show q
errorMessage (UnknownField name t) = "Record type " <> typeMessage t <> " has no field " <> show name

typeMessage :: (Abstract.Nameable l, Abstract.Oberon l) => Type l -> String
typeMessage (BuiltinType name) = Text.unpack name
typeMessage (NominalType name _) = nameMessage name
typeMessage (RecordType ancestry fields) = 
   "RECORD " ++ foldMap (("(" ++) . (++ ") ") . nameMessage) ancestry
   ++ List.intercalate ";\n" (fieldMessage <$> Map.toList fields) ++ "END"
   where fieldMessage (name, t) = "\n  " <> Text.unpack name <> ": " <> typeMessage t
typeMessage (ArrayType dimensions itemType) = 
   "ARRAY " ++ List.intercalate ", " (show <$> dimensions) ++ " OF " ++ typeMessage itemType
typeMessage (PointerType targetType) = "POINTER TO " ++ typeMessage targetType
typeMessage (ProcedureType _ parameters result) =
   "PROCEDURE (" ++ List.intercalate ", " (argMessage <$> parameters) ++ "): " ++ foldMap typeMessage result
   where argMessage (True, t) = "VAR " <> typeMessage t
         argMessage (False, t) = typeMessage t
typeMessage (ReceiverType t) = typeMessage t
typeMessage (IntegerType n) = "INTEGER"
typeMessage (StringType len) = "STRING [" ++ shows len "]"
typeMessage NilType = "NIL"
typeMessage UnknownType = "[Unknown]"

nameMessage :: (Abstract.Nameable l, Abstract.Oberon l) => Abstract.QualIdent l -> String
nameMessage q
   | Just (mod, name) <- Abstract.getQualIdentNames q = Text.unpack mod <> "." <> Text.unpack name
   | Just name <- Abstract.getNonQualIdentName q = Text.unpack name

type Environment l = Map (Abstract.QualIdent l) (Type l)

newtype Modules l f' f = Modules (Map AST.Ident (f (AST.Module l l f' f')))

data TypeCheck = TypeCheck

type Sem = Semantics (Auto TypeCheck)

data InhTCRoot l = InhTCRoot{rootEnv :: Environment l}

data InhTC l = InhTC{env :: Environment l}
               deriving Generic

data InhTCExp l = InhTCExp{env          :: Environment l,
                           expectedType :: Type l}
                  deriving Generic

data InhTCDecl l = InhTCDecl{env           :: Environment l,
                             pointerTargets :: Map AST.Ident AST.Ident}
                   deriving Generic

data SynTC l = SynTC{errors :: Folded [Error () l]}
               deriving Generic

data SynTCMods l = SynTCMods{errors :: Folded [Error AST.Ident l]}
                   deriving Generic

data SynTCMod l = SynTCMod{errors :: Folded [Error () l],
                           moduleEnv :: Environment l,
                           pointerTargets :: Folded (Map AST.Ident AST.Ident)}
                  deriving Generic

data SynTCType l = SynTCType{errors :: Folded [Error () l],
                             typeName   :: Maybe AST.Ident,
                             definedType :: Type l,
                             pointerTarget :: Maybe AST.Ident}
                   deriving Generic

data SynTCFields l = SynTCFields{errors :: Folded [Error () l],
                                 fieldEnv :: Map AST.Ident (Type l)}
                     deriving Generic

data SynTCHead l = SynTCHead{errors :: Folded [Error () l],
                             insideEnv :: Environment l,
                             outsideEnv :: Environment l}
                   deriving Generic

data SynTCSig l = SynTCSig{errors :: Folded [Error () l],
                           signatureEnv :: Environment l,
                           signatureType :: Type l}
                  deriving Generic

data SynTCSec l = SynTCSec{errors :: Folded [Error () l],
                           sectionEnv :: Environment l,
                           sectionParameters :: [(Bool, Type l)]}
                  deriving Generic

data SynTCDes l = SynTCDes{errors :: Folded [Error () l],
                           designatorName   :: Maybe (Maybe Abstract.Ident, Abstract.Ident),
                           designatorType :: Type l}
                  deriving Generic

data SynTCExp l = SynTCExp{errors :: Folded [Error () l],
                           inferredType :: Type l}
                  deriving Generic

-- * Modules instances, TH candidates
instance (Transformation.Transformation t, Functor (Transformation.Domain t), Deep.Functor t (AST.Module l l),
          Transformation.At t (AST.Module l l (Transformation.Codomain t) (Transformation.Codomain t))) =>
         Deep.Functor t (Modules l) where
   t <$> ~(Modules ms) = Modules (mapModule <$> ms)
      where mapModule m = t Transformation.$ ((t Deep.<$>) <$> m)
instance (Transformation.Transformation t, Functor (Transformation.Domain t),
          Transformation.At t (AST.Module l l f f)) =>
         Shallow.Functor t (Modules l f) where
   t <$> ~(Modules ms) = Modules ((t Transformation.$) <$> ms)
instance (Transformation.Transformation t, Functor (Transformation.Domain t), Shallow.Foldable t (AST.Module l l f),
          Transformation.At t (AST.Module l l f f)) =>
         Shallow.Foldable t (Modules l f) where
   foldMap t ~(Modules ms) = getConst (foldMap (t Transformation.$) ms)

instance Rank2.Functor (Modules l f') where
   f <$> ~(Modules ms) = Modules (f <$> ms)
instance Rank2.Foldable (Modules l f) where
   foldMap f ~(Modules ms) = foldMap f ms
instance Rank2.Apply (Modules l f') where
   ~(Modules fs) <*> ~(Modules ms) = Modules (Map.intersectionWith Rank2.apply fs ms)

-- * Boring attribute types
type instance Atts (Inherited TypeCheck) (Modules l _ _) = InhTCRoot l
type instance Atts (Synthesized TypeCheck) (Modules l _ _) = SynTCMods l
type instance Atts (Inherited TypeCheck) (AST.Module l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Module l l _ _) = SynTCMod l
type instance Atts (Inherited TypeCheck) (AST.Declaration l l _ _) = InhTCDecl l
type instance Atts (Synthesized TypeCheck) (AST.Declaration l l _ _) = SynTCMod l
type instance Atts (Inherited TypeCheck) (AST.ProcedureHeading l l _ _) = InhTCDecl l
type instance Atts (Synthesized TypeCheck) (AST.ProcedureHeading l l _ _) = SynTCHead l
type instance Atts (Inherited TypeCheck) (AST.Block l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Block l l _ _) = SynTCMod l
type instance Atts (Inherited TypeCheck) (AST.FormalParameters l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.FormalParameters l l _ _) = SynTCSig l
type instance Atts (Inherited TypeCheck) (AST.FPSection l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.FPSection l l _ _) = SynTCSec l
type instance Atts (Inherited TypeCheck) (AST.Type l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Type l l _ _) = SynTCType l
type instance Atts (Inherited TypeCheck) (AST.FieldList l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.FieldList l l _ _) = SynTCFields l
type instance Atts (Inherited TypeCheck) (AST.StatementSequence l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.StatementSequence l l _ _) = SynTC l
type instance Atts (Inherited TypeCheck) (AST.Expression l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Expression l l _ _) = SynTCExp l
type instance Atts (Inherited TypeCheck) (AST.Element l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Element l l _ _) = SynTCExp l
type instance Atts (Inherited TypeCheck) (AST.Value l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Value l l _ _) = SynTCExp l
type instance Atts (Inherited TypeCheck) (AST.Designator l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Designator l l _ _) = SynTCDes l
type instance Atts (Inherited TypeCheck) (AST.Statement l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.Statement l l _ _) = SynTC l
type instance Atts (Inherited TypeCheck) (AST.ConditionalBranch l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.ConditionalBranch l l _ _) = SynTC l
type instance Atts (Inherited TypeCheck) (AST.Case l l _ _) = InhTCExp l
type instance Atts (Synthesized TypeCheck) (AST.Case l l _ _) = SynTC l
type instance Atts (Inherited TypeCheck) (AST.CaseLabels l l _ _) = InhTCExp l
type instance Atts (Synthesized TypeCheck) (AST.CaseLabels l l _ _) = SynTC l
type instance Atts (Inherited TypeCheck) (AST.WithAlternative l l _ _) = InhTC l
type instance Atts (Synthesized TypeCheck) (AST.WithAlternative l l _ _) = SynTC l

-- * Rules

instance Ord (Abstract.QualIdent l) => Bequether (Auto TypeCheck) (Modules l) Sem Placed where
   bequest _ (_, Modules self) inheritance (Modules ms) =
     Modules (Map.mapWithKey moduleInheritance self)
     where moduleInheritance name mod = Inherited InhTC{env= rootEnv inheritance <> foldMap (moduleEnv . syn) ms}
instance Ord (Abstract.QualIdent l) => Synthesizer (Auto TypeCheck) (Modules l) Sem Placed where
  synthesis _ _ _ (Modules ms) = SynTCMods{errors= Map.foldMapWithKey moduleErrors ms}
     where moduleErrors name (Synthesized SynTCMod{errors= Folded errs}) =
              Folded [Error name pos t | Error () pos t <- errs]

instance (Abstract.Oberon l, Abstract.Nameable l, k ~ Abstract.QualIdent l, Ord k,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Block l l Sem Sem) ~ SynTCMod l) =>
         SynthesizedField "moduleEnv" (Map k (Type l)) (Auto TypeCheck) (AST.Module l l) Sem Placed where
   synthesizedField _ _ (pos, AST.Module moduleName imports body) _inheritance (AST.Module _ _ body') = exportedEnv
      where exportedEnv = exportNominal <$> Map.mapKeysMonotonic export (moduleEnv $ syn body')
            export q
               | Just name <- Abstract.getNonQualIdentName q = Abstract.qualIdent moduleName name
               | otherwise = q
            exportNominal (NominalType q (Just t))
               | Just name <- Abstract.getNonQualIdentName q =
                 NominalType (Abstract.qualIdent moduleName name) (Just $ exportNominal' t)
            exportNominal t = exportNominal' t
            exportNominal' (RecordType ancestry fields) = RecordType (export <$> ancestry) (exportNominal' <$> fields)
            exportNominal' (ProcedureType False parameters result) =
              ProcedureType False ((exportNominal' <$>) <$> parameters) (exportNominal' <$> result)
            exportNominal' (PointerType target) = PointerType (exportNominal' target)
            exportNominal' (ArrayType dimensions itemType) = ArrayType dimensions (exportNominal' itemType)
            exportNominal' (NominalType q (Just t))
              | Just name <- Abstract.getNonQualIdentName q =
                fromMaybe (NominalType (Abstract.qualIdent moduleName name) $ Just $ exportNominal' t)
                          (Map.lookup q exportedEnv)
            exportNominal' t = t

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited (Auto TypeCheck)) (Abstract.Type l l Sem Sem) ~ InhTC l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.ProcedureHeading l l Sem Sem) ~ InhTCDecl l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.Block l l Sem Sem) ~ InhTC l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.ProcedureHeading l l Sem Sem) ~ SynTCHead l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.FormalParameters l l Sem Sem) ~ InhTC l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.ConstExpression l l Sem Sem) ~ InhTC l) =>
         Bequether (Auto TypeCheck) (AST.Declaration l l) Sem Placed where
   bequest _ (pos, AST.ProcedureDeclaration{})
           inheritance@InhTCDecl{env= declEnv} (AST.ProcedureDeclaration heading _body) =
      AST.ProcedureDeclaration (Inherited inheritance) (Inherited bodyInherited)
      where bodyInherited = InhTC{env= insideEnv (syn heading) `Map.union` declEnv}
   bequest t local inheritance synthesized = AG.bequestDefault t local inheritance synthesized

instance (Abstract.Nameable l, k ~ Abstract.QualIdent l, Ord k,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Declaration l l Sem Sem) ~ SynTCMod l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Type l l Sem Sem) ~ SynTCType l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.FormalParameters l l Sem Sem) ~ SynTCSig l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.ProcedureHeading l l Sem Sem) ~ SynTCHead l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.ConstExpression l l Sem Sem) ~ SynTCExp l) =>
         SynthesizedField "moduleEnv" (Map k (Type l)) (Auto TypeCheck) (AST.Declaration l l) Sem Placed where
   synthesizedField _ _ (pos, AST.ConstantDeclaration namedef _) _ (AST.ConstantDeclaration _ expression) =
      Map.singleton (Abstract.nonQualIdent $ Abstract.getIdentDefName namedef) (inferredType $ syn expression)
   synthesizedField _ _ (pos, AST.TypeDeclaration namedef _) _ (AST.TypeDeclaration _ definition) =
      Map.singleton qname (nominal $ definedType $ syn definition)
      where nominal t@BuiltinType{} = t
            nominal t@NominalType{} = t
            nominal (PointerType t@RecordType{}) =
               NominalType qname (Just $ PointerType $ NominalType (Abstract.nonQualIdent $ name<>"^") (Just t))
            nominal t = NominalType qname (Just t)
            qname = Abstract.nonQualIdent name
            name = Abstract.getIdentDefName namedef
   synthesizedField _ _ (pos, AST.VariableDeclaration names _) _ (AST.VariableDeclaration _names declaredType) =
      foldMap binding names
      where binding name = Map.singleton (Abstract.nonQualIdent $ Abstract.getIdentDefName name)
                                         (definedType $ syn declaredType)
   synthesizedField _ _ (pos, AST.ProcedureDeclaration{}) _ (AST.ProcedureDeclaration heading body) =
      outsideEnv (syn heading)
   synthesizedField _ _ (pos, AST.ForwardDeclaration namedef _sig) _ (AST.ForwardDeclaration _namedef sig) =
      foldMap (Map.singleton (Abstract.nonQualIdent $ Abstract.getIdentDefName namedef) . signatureType . syn) sig

instance (Abstract.Nameable l, k ~ Abstract.QualIdent l, Ord k,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Type l l Sem Sem) ~ SynTCType l) =>
         SynthesizedField "pointerTargets" (Folded (Map AST.Ident AST.Ident)) (Auto TypeCheck)
                                           (AST.Declaration l l) Sem Placed where
   synthesizedField _ _ (pos, AST.TypeDeclaration namedef _) _ (AST.TypeDeclaration _ definition) =
      foldMap (Folded . Map.singleton name) (pointerTarget $ syn definition)
      where name = Abstract.getIdentDefName namedef
   synthesizedField _ _ _ _ _ = mempty

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Synthesized (Auto TypeCheck)) (Abstract.FormalParameters l l Sem Sem) ~ SynTCSig l) =>
         Synthesizer (Auto TypeCheck) (AST.ProcedureHeading l l) Sem Placed where
   synthesis _ (pos, AST.ProcedureHeading indirect namedef _sig) _inheritance (AST.ProcedureHeading _indirect _ sig) =
      SynTCHead{errors= foldMap (\s-> errors (syn s :: SynTCSig l)) sig,
                outsideEnv= Map.singleton (Abstract.nonQualIdent name) $
                            maybe (ProcedureType False [] Nothing) (signatureType . syn) sig,
                insideEnv= foldMap (signatureEnv . syn) sig}
      where name = Abstract.getIdentDefName namedef
   synthesis _ (pos, AST.TypeBoundHeading var receiverName receiverType indirect namedef _sig)
             InhTCDecl{env, pointerTargets} (AST.TypeBoundHeading _var _name _type _indirect _ sig) =
      SynTCHead{errors= receiverError <> foldMap (\s-> errors (syn s :: SynTCSig l)) sig,
                outsideEnv= case Map.lookup receiverType pointerTargets
                            of Just targetName -> Map.singleton (Abstract.nonQualIdent targetName) methodType
                               Nothing -> Map.singleton (Abstract.nonQualIdent receiverType) methodType,
                insideEnv= receiverEnv `Map.union` foldMap (signatureEnv . syn) sig}
      where receiverEnv =
               foldMap (Map.singleton (Abstract.nonQualIdent receiverName) . ReceiverType)
                       (Map.lookup (Abstract.nonQualIdent receiverType) env)
            methodType = NominalType (Abstract.nonQualIdent "")
                                     (Just $ RecordType [] $ Map.singleton name procedureType)
            name = Abstract.getIdentDefName namedef
            procedureType = maybe (ProcedureType False [] Nothing) (signatureType . syn) sig
            receiverError =
               case Map.lookup (Abstract.nonQualIdent receiverType) env
               of Nothing -> Folded [Error () pos (UnknownName $ Abstract.nonQualIdent receiverType)]
                  Just t 
                     | RecordType{} <- ultimate t -> mempty
                     | PointerType t' <- ultimate t, RecordType{} <- ultimate t' -> mempty
                     | otherwise -> Folded [Error () pos (NonRecordType t)]

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l), Show (Abstract.QualIdent l),
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Declaration l l Sem Sem) ~ SynTCMod l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.Declaration l l Sem Sem) ~ InhTCDecl l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.StatementSequence l l Sem Sem) ~ InhTC l) =>
         Bequether (Auto TypeCheck) (AST.Block l l) Sem Placed where
   bequest _ (pos, AST.Block{}) inheritance@InhTC{env} (AST.Block declarations _statements) =
      AST.Block (pure $ Inherited InhTCDecl{env= localEnv,
                                            pointerTargets= getFolded pointers})
                (pure $ Inherited localInheritance)
      where localInheritance :: InhTC l
            localInheritance = inheritance{env= localEnv}
            localEnv = newEnv declarations <> env
            pointers= foldMap (\Synthesized{syn= SynTCMod{pointerTargets= ptrs}}-> ptrs) declarations

instance (Abstract.Nameable l, k ~ Abstract.QualIdent l, Ord k, Show k,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Declaration l l Sem Sem) ~ SynTCMod l) =>
         SynthesizedField "moduleEnv" (Map k (Type l)) (Auto TypeCheck) (AST.Block l l) Sem Placed where
   synthesizedField _ _ (pos, AST.Block{}) _inheritance (AST.Block declarations _statements) = newEnv declarations

newEnv :: (Abstract.Nameable l, Ord (Abstract.QualIdent l), Show (Abstract.QualIdent l),
           Atts (Synthesized (Auto TypeCheck)) (Abstract.Declaration l l Sem Sem) ~ SynTCMod l) =>
          ZipList (Synthesized (Auto TypeCheck) (Abstract.Declaration l l Sem Sem)) -> Environment l
newEnv declarations = Map.unionsWith mergeTypeBoundProcedures (moduleEnv . syn <$> declarations)
   where mergeTypeBoundProcedures (NominalType q (Just t1)) t2
            | Abstract.getNonQualIdentName q == Just "" = mergeTypeBoundProcedures t1 t2
            | otherwise = NominalType q (Just $ mergeTypeBoundProcedures t1 t2)
         mergeTypeBoundProcedures t1 (NominalType q (Just t2))
            | Abstract.getNonQualIdentName q == Just "" = mergeTypeBoundProcedures t1 t2
            | otherwise = NominalType q (Just $ mergeTypeBoundProcedures t1 t2)
         mergeTypeBoundProcedures (RecordType ancestry1 fields1) (RecordType ancestry2 fields2) =
            RecordType (ancestry1 <> ancestry2) (fields1 <> fields2)
         mergeTypeBoundProcedures (PointerType (RecordType ancestry1 fields1)) (RecordType ancestry2 fields2) =
            PointerType (RecordType (ancestry1 <> ancestry2) (fields1 <> fields2))
         mergeTypeBoundProcedures (RecordType ancestry1 fields1) (PointerType (RecordType ancestry2 fields2)) =
            PointerType (RecordType (ancestry1 <> ancestry2) (fields1 <> fields2))
         mergeTypeBoundProcedures (PointerType (NominalType q (Just (RecordType ancestry1 fields1))))
                                  (RecordType ancestry2 fields2) =
            PointerType (NominalType q $ Just $ RecordType (ancestry1 <> ancestry2) (fields1 <> fields2))
         mergeTypeBoundProcedures (RecordType ancestry1 fields1)
                                  (PointerType (NominalType q (Just (RecordType ancestry2 fields2)))) =
            PointerType (NominalType q $ Just $ RecordType (ancestry1 <> ancestry2) (fields1 <> fields2))
         mergeTypeBoundProcedures t1 t2 = error (take 90 $ show t1)
            
instance (Ord (Abstract.QualIdent l),
          Atts (Synthesized (Auto TypeCheck)) (Abstract.FPSection l l Sem Sem) ~ SynTCSec l) =>
         Synthesizer (Auto TypeCheck) (AST.FormalParameters l l) Sem Placed where
   synthesis _ (pos, AST.FormalParameters sections returnType) InhTC{env}
             (AST.FormalParameters sections' _) =
      SynTCSig{errors= foldMap (\s-> errors (syn s :: SynTCSec l)) sections'
                       <> foldMap typeRefErrors returnType,
               signatureType= ProcedureType False (foldMap (sectionParameters . syn) sections')
                              $ returnType >>= (`Map.lookup` env),
               signatureEnv= foldMap (sectionEnv . syn) sections'}
      where typeRefErrors q
               | Map.member q env = mempty
               | otherwise = Folded [Error () pos (UnknownName q)]

instance (Abstract.Wirthy l, Ord (Abstract.QualIdent l),
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Type l l Sem Sem) ~ SynTCType l) =>
         Synthesizer (Auto TypeCheck) (AST.FPSection l l) Sem Placed where
   synthesis _ (pos, AST.FPSection var names _typeDef) _inheritance (AST.FPSection _var _names typeDef) =
      SynTCSec{errors= errors (syn typeDef :: SynTCType l),
               sectionParameters= (var, definedType (syn typeDef)) <$ names,
               sectionEnv= Map.fromList (flip (,) (definedType $ syn typeDef) . Abstract.nonQualIdent <$> names)}

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Synthesized (Auto TypeCheck)) (Abstract.FormalParameters l l Sem Sem) ~ SynTCSig l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.FieldList l l Sem Sem) ~ SynTCFields l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Type l l Sem Sem) ~ SynTCType l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.ConstExpression l l Sem Sem) ~ SynTCExp l) =>
         Synthesizer (Auto TypeCheck) (AST.Type l l) Sem Placed where
   synthesis _ (pos, AST.TypeReference q) InhTC{env} _ = 
      SynTCType{errors= if Map.member q env then mempty else Folded [Error () pos (UnknownName q)],
                typeName= Abstract.getNonQualIdentName q,
                pointerTarget= Nothing,
                definedType= fromMaybe UnknownType (Map.lookup q env)}
   synthesis _ (pos, AST.ArrayType _dims _itemType) InhTC{} (AST.ArrayType dimensions itemType) =
      SynTCType{errors= foldMap (\d-> errors (syn d :: SynTCExp l)) dimensions
                        <> errors (syn itemType :: SynTCType l)
                        <> foldMap (expectInteger . syn) dimensions,
                typeName= Nothing,
                pointerTarget= Nothing,
                definedType= ArrayType (integerValue . syn <$> getZipList dimensions) (definedType $ syn itemType)}
     where expectInteger SynTCExp{inferredType= IntegerType{}} = mempty
           expectInteger SynTCExp{inferredType= t} = Folded [Error () pos (NonIntegerType t)]
           integerValue SynTCExp{inferredType= IntegerType n} = n
           integerValue _ = 0
   synthesis _ (pos, AST.RecordType base fields) InhTC{env} (AST.RecordType _base fields') =
      SynTCType{errors= fst baseRecord <> foldMap (\f-> errors (syn f :: SynTCFields l)) fields',
                typeName= Nothing,
                pointerTarget= Nothing,
                definedType= RecordType (maybe [] (maybe id (:) base . ancestry) $ snd baseRecord)
                                        (maybe Map.empty recordFields (snd baseRecord)
                                         <> foldMap (fieldEnv . syn) fields')}
     where baseRecord = case flip Map.lookup env <$> base
                        of Just (Just t@RecordType{}) -> (mempty, Just t)
                           Just (Just (NominalType _ (Just t@RecordType{}))) -> (mempty, Just t)
                           Just (Just t) -> (Folded [Error () pos (NonRecordType t)], Nothing)
                           Just Nothing ->
                              (foldMap (Folded . (:[]) . Error () pos . UnknownName) base, Nothing)
                           Nothing -> (mempty, Nothing)
   synthesis (Auto TypeCheck) _self _inheritance (AST.PointerType targetType') =
      SynTCType{errors= errors (syn targetType' :: SynTCType l),
                typeName= Nothing,
                pointerTarget= typeName (syn targetType'),
                definedType= PointerType (definedType $ syn targetType')}
   synthesis _ (pos, AST.ProcedureType signature) _inheritance (AST.ProcedureType signature') = 
      SynTCType{errors= foldMap (\s-> errors (syn s :: SynTCSig l)) signature',
                typeName= Nothing,
                pointerTarget= Nothing,
                definedType= maybe (ProcedureType False [] Nothing) (signatureType . syn) signature'}

instance (Abstract.Nameable l, Atts (Synthesized (Auto TypeCheck)) (Abstract.Type l l Sem Sem) ~ SynTCType l) =>
         SynthesizedField "fieldEnv" (Map AST.Ident (Type l)) (Auto TypeCheck) (AST.FieldList l l) Sem Placed where
   synthesizedField _ _ (_, AST.FieldList names _declaredType) _inheritance (AST.FieldList _names declaredType) =
      foldMap (\name-> Map.singleton (Abstract.getIdentDefName name) (definedType $ syn declaredType)) names

instance (Abstract.Wirthy l, Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited (Auto TypeCheck)) (Abstract.StatementSequence l l Sem Sem) ~ InhTC l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.ConditionalBranch l l Sem Sem) ~ InhTC l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.Case l l Sem Sem) ~ InhTCExp l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.WithAlternative l l Sem Sem) ~ InhTC l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ InhTC l,
          Atts (Inherited (Auto TypeCheck)) (Abstract.Designator l l Sem Sem) ~ InhTC l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ SynTCExp l) =>
         Bequether (Auto TypeCheck) (AST.Statement l l) Sem Placed where
   bequest _ (_pos, AST.CaseStatement{}) i@InhTC{env} (AST.CaseStatement value _branches _fallback) =
      AST.CaseStatement (Inherited i) (pure $ Inherited InhTCExp{env= env,
                                                                 expectedType= inferredType $ syn value})
                        (Just $ Inherited i)
   bequest _ (_pos, statement) InhTC{env} _ =
      AG.passDown InhTCExp{env= env,
                           expectedType= error "No statement except CASE needs expectedType"} statement

instance {-# overlaps #-} (Abstract.Wirthy l, Abstract.Nameable l, Ord (Abstract.QualIdent l),
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.StatementSequence l l Sem Sem) ~ SynTC l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ SynTCExp l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Designator l l Sem Sem) ~ SynTCDes l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Case l l Sem Sem) ~ SynTC l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.ConditionalBranch l l Sem Sem) ~ SynTC l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.WithAlternative l l Sem Sem) ~ SynTC l) =>
                          Synthesizer (Auto TypeCheck) (AST.Statement l l) Sem Placed where
   synthesis t (pos, _) InhTC{} statement@(AST.Assignment var value) =
      {-# SCC "Assignment" #-}
      SynTC{errors= assignmentCompatible pos (designatorType $ syn var) (inferredType $ syn value)
                    <> AG.foldedField (Proxy :: Proxy "errors") t statement}
   synthesis _ (pos, AST.ProcedureCall _proc parameters) _inheritance (AST.ProcedureCall procedure' parameters') =
      SynTC{errors= (case syn procedure'
                     of SynTCDes{errors= Folded [],
                                 designatorType= t} -> procedureErrors t
                        SynTCDes{errors= errs} -> errs)
                    <> foldMap (foldMap (\p-> errors (syn p :: SynTCExp l))) parameters'}
     where procedureErrors (ProcedureType _ formalTypes Nothing)
             | length formalTypes /= maybe 0 (length . getZipList) parameters,
               not (length formalTypes == 2 && (length . getZipList <$> parameters) == Just 1
                    && designatorName (syn procedure') == Just (Nothing, "ASSERT")
                    || length formalTypes == 1 && (length . getZipList <$> parameters) == Just 2
                    && designatorName (syn procedure') == Just (Nothing, "NEW")
                    && all (all (isIntegerType . inferredType . syn) . tail . getZipList) parameters') =
                 Folded [Error () pos
                         $ ArgumentCountMismatch (length formalTypes) $ maybe 0 (length . getZipList) parameters]
             | otherwise = mconcat (zipWith (parameterCompatible pos) formalTypes
                                    $ maybe [] ((inferredType . syn <$>) . getZipList) parameters')
           procedureErrors (NominalType _ (Just t)) = procedureErrors t
           procedureErrors t = Folded [Error () pos (NonProcedureType t)]
   synthesis _ (pos, _) _inheritance (AST.While condition body) =
      SynTC{errors= booleanExpressionErrors pos (syn condition) <> errors (syn body :: SynTC l)}
   synthesis _ (pos, _) _inheritance (AST.Repeat body condition) =
      SynTC{errors= booleanExpressionErrors pos (syn condition) <> errors (syn body :: SynTC l)}
   synthesis _ (pos, _) _inheritance (AST.For _counter start end step body) =
      SynTC{errors= integerExpressionErrors pos (syn start) 
                    <> integerExpressionErrors pos (syn end)
                    <> foldMap (integerExpressionErrors pos . syn) step <> errors (syn body :: SynTC l)}
   synthesis t self _ statement = SynTC{errors= AG.foldedField (Proxy :: Proxy "errors") t statement}

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited (Auto TypeCheck)) (Abstract.StatementSequence l l Sem Sem) ~ InhTC l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.StatementSequence l l Sem Sem) ~ SynTC l) =>
         Attribution (Auto TypeCheck) (AST.WithAlternative l l) Sem Placed where
   attribution _ (pos, AST.WithAlternative var subtype _body)
               (Inherited InhTC{env},
                AST.WithAlternative _var _subtype body) =
      (Synthesized SynTC{errors= case (Map.lookup var env, Map.lookup subtype env)
                                 of (Just supertype, Just subtypeDef) ->
                                      assignmentCompatible pos supertype subtypeDef
                                    (Nothing, _) -> Folded [Error () pos (UnknownName var)]
                                    (_, Nothing) -> Folded [Error () pos (UnknownName subtype)]
                                 <> errors (syn body :: SynTC l)},
       AST.WithAlternative var subtype (Inherited $ InhTC $ maybe id (Map.insert var) (Map.lookup subtype env) env))

instance (Abstract.Nameable l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ SynTCExp l,
          Atts (Synthesized (Auto TypeCheck)) (Abstract.StatementSequence l l Sem Sem) ~ SynTC l) =>
         Synthesizer (Auto TypeCheck) (AST.ConditionalBranch l l) Sem Placed where
   synthesis _ (pos, _) _inheritance (AST.ConditionalBranch condition body) =
      SynTC{errors= booleanExpressionErrors pos (syn condition) <> errors (syn body :: SynTC l)}

instance {-# overlaps #-} (Abstract.Nameable l, Eq (Abstract.QualIdent l),
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.ConstExpression l l Sem Sem) ~ SynTCExp l) =>
                          Synthesizer (Auto TypeCheck) (AST.CaseLabels l l) Sem Placed where
   synthesis _ (pos, _) inheritance (AST.SingleLabel value) =
      SynTC{errors= assignmentCompatibleIn inheritance pos (inferredType $ syn value)}
   synthesis _ (pos, _) inheritance (AST.LabelRange start end) =
      SynTC{errors= assignmentCompatibleIn inheritance pos (inferredType $ syn start)
                    <> assignmentCompatibleIn inheritance pos (inferredType $ syn end)}

instance {-# overlaps #-} (Abstract.Nameable l, Ord (Abstract.QualIdent l),
                           Atts (Inherited (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ InhTC l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ SynTCExp l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Element l l Sem Sem) ~ SynTCExp l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Value l l Sem Sem) ~ SynTCExp l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Designator l l Sem Sem) ~ SynTCDes l) =>
                          Synthesizer (Auto TypeCheck) (AST.Expression l l) Sem Placed where
   synthesis _ (pos, AST.Relation op _ _) InhTC{} (AST.Relation _op left right) =
      SynTCExp{errors= case errors (syn left :: SynTCExp l) <> errors (syn right :: SynTCExp l)
                       of Folded []
                            | t1 == t2 -> mempty
                            | AST.In <- op -> membershipCompatible (ultimate t1) (ultimate t2)
                            | equality op,
                              Folded [] <- assignmentCompatible pos t1 t2
                              -> mempty
                            | equality op,
                              Folded [] <- assignmentCompatible pos t2 t1
                              -> mempty
                            | otherwise -> comparable (ultimate t1) (ultimate t2)
                          errs -> errs,
               inferredType= BuiltinType "BOOLEAN"}
      where t1 = inferredType (syn left)
            t2 = inferredType (syn right)
            equality AST.Equal = True
            equality AST.Unequal = True
            equality _ = False
            comparable (BuiltinType "BOOLEAN") (BuiltinType "BOOLEAN") = mempty
            comparable (BuiltinType "CHAR") (BuiltinType "CHAR") = mempty
            comparable StringType{} StringType{} = mempty
            comparable (StringType 1) (BuiltinType "CHAR") = mempty
            comparable (BuiltinType "CHAR") (StringType 1) = mempty
            comparable StringType{} (ArrayType _ (BuiltinType "CHAR")) = mempty
            comparable (ArrayType _ (BuiltinType "CHAR")) StringType{} = mempty
            comparable (ArrayType _ (BuiltinType "CHAR")) (ArrayType _ (BuiltinType "CHAR")) = mempty
            comparable (BuiltinType t1) (BuiltinType t2)
               | isNumerical t1 && isNumerical t2 = mempty
            comparable (BuiltinType t1) IntegerType{}
               | isNumerical t1 = mempty
            comparable IntegerType{} (BuiltinType t2)
               | isNumerical t2 = mempty
            comparable t1 t2 = Folded [Error () pos (IncomparableTypes t1 t2)]
            membershipCompatible IntegerType{} (BuiltinType "SET") = mempty
            membershipCompatible (BuiltinType t1) (BuiltinType "SET")
               | isNumerical t1 = mempty
   synthesis _ (pos, AST.IsA _ q) InhTC{env} (AST.IsA left _) =
      SynTCExp{errors= case Map.lookup q env
                       of Nothing -> Folded [Error () pos (UnknownName q)]
                          Just t -> assignmentCompatible pos (inferredType $ syn left) t,
               inferredType= BuiltinType "BOOLEAN"}
   synthesis _ (pos, _) _inheritance (AST.Positive expr) =
      SynTCExp{errors= unaryNumericOrSetOperatorErrors pos (syn expr),
               inferredType= inferredType (syn expr)}
   synthesis _ (pos, _) _inheritance (AST.Negative expr) =
      SynTCExp{errors= unaryNumericOrSetOperatorErrors pos (syn expr),
               inferredType= unaryNumericOrSetOperatorType negate (syn expr)}
   synthesis _ (pos, _) _inheritance (AST.Add left right) = binaryNumericOrSetSynthesis pos left right
   synthesis _ (pos, _) _inheritance (AST.Subtract left right) = binaryNumericOrSetSynthesis pos left right
   synthesis _ (pos, _) _inheritance (AST.Or left right) = binaryBooleanSynthesis pos left right
   synthesis _ (pos, _) _inheritance (AST.Multiply left right) = binaryNumericOrSetSynthesis pos left right
   synthesis _ (pos, _) InhTC{} (AST.Divide left right) =
      SynTCExp{errors=
                  case (syn left, syn right)
                  of (SynTCExp{errors= Folded [], inferredType= BuiltinType t1},
                      SynTCExp{errors= Folded [], inferredType= BuiltinType t2})
                        | t1 == "REAL", t2 == "REAL" -> mempty
                        | t1 == "SET", t2 == "SET" -> mempty
                     (SynTCExp{errors= Folded [], inferredType= t1},
                      SynTCExp{errors= Folded [], inferredType= t2})
                       | t1 == t2 -> Folded [Error () pos (UnrealType t1)]
                       | otherwise -> Folded [Error () pos (TypeMismatch t1 t2)],
               inferredType= BuiltinType "REAL"}
   synthesis _ (pos, _) _inheritance (AST.IntegerDivide left right) = binaryIntegerSynthesis pos left right
   synthesis _ (pos, _) _inheritance (AST.Modulo left right) = binaryIntegerSynthesis pos left right
   synthesis _ (pos, _) _inheritance (AST.And left right) = binaryBooleanSynthesis pos left right
   synthesis (Auto TypeCheck) _self _ (AST.Set elements) =
      SynTCExp{errors= mempty,
               inferredType= BuiltinType "SET"}
   synthesis (Auto TypeCheck) _self _ (AST.Read designator) =
      SynTCExp{errors= errors (syn designator :: SynTCDes l),
               inferredType= designatorType (syn designator)}
   synthesis (Auto TypeCheck) _self _ (AST.Literal value) =
      SynTCExp{errors= errors (syn value :: SynTCExp l),
               inferredType= inferredType (syn value)}
   synthesis _ (pos, AST.FunctionCall _designator (ZipList parameters)) _inheritance
             (AST.FunctionCall designator (ZipList parameters')) =
      SynTCExp{errors=
                   case {-# SCC "FunctionCall" #-} syn designator
                   of SynTCDes{errors= Folded [],
                               designatorName= name,
                               designatorType= ultimate -> ProcedureType _ formalTypes Just{}}
                        | length formalTypes /= length parameters ->
                            Folded [Error () pos
                                    $ ArgumentCountMismatch (length formalTypes) (length parameters)]
                        | name == Just (Just "SYSTEM", "VAL") -> mempty
                        | otherwise -> mconcat (zipWith (parameterCompatible pos) formalTypes
                                                $ inferredType . syn <$> parameters')
                      SynTCDes{errors= Folded [],
                               designatorType= t} -> Folded [Error () pos (NonFunctionType t)]
                      SynTCDes{errors= errs} -> errs
                   <> foldMap (\p-> errors (syn p :: SynTCExp l)) parameters',
               inferredType=
                   case syn designator
                   of SynTCDes{designatorName= Just (Just "SYSTEM", name)}
                        | Just t <- systemCallType name (inferredType . syn <$> parameters') -> t
                      SynTCDes{designatorName= d, designatorType= t}
                        | ProcedureType _ _ (Just returnType) <- ultimate t -> returnType
                      _ -> UnknownType}
     where systemCallType "VAL" [t1, t2] = Just t1
           systemCallType _ _ = Nothing
   synthesis _ (pos, _) _inheritance (AST.Not expr) =
      SynTCExp{errors= booleanExpressionErrors pos (syn expr),
               inferredType= BuiltinType "BOOLEAN"}
  
instance Abstract.Wirthy l => SynthesizedField "inferredType" (Type l) (Auto TypeCheck) (AST.Value l l) Sem Placed where
   synthesizedField _ _ (_, AST.Integer x) _ _  = IntegerType (fromIntegral x)
   synthesizedField _ _ (_, AST.Real x) _ _     = BuiltinType "REAL"
   synthesizedField _ _ (_, AST.Boolean x) _ _  = BuiltinType "BOOLEAN"
   synthesizedField _ _ (_, AST.CharCode x) _ _ = BuiltinType "CHAR"
   synthesizedField _ _ (_, AST.String x) _ _   = StringType (Text.length x)
   synthesizedField _ _ (_, AST.Nil) _ _        = NilType
   synthesizedField _ _ (_, AST.Builtin x) _ _  = BuiltinType x

instance (Atts (Synthesized (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ SynTCExp l) =>
         SynthesizedField "errors" (Folded [Error () l]) (Auto TypeCheck) (AST.Element l l) Sem Placed where
   synthesizedField _ _ (pos, _) _inheritance (AST.Element expr) = integerExpressionErrors pos (syn expr)
   synthesizedField _ _ (pos, _) _inheritance (AST.Range low high) = integerExpressionErrors pos (syn high)
                                                                     <> integerExpressionErrors pos (syn low)

instance SynthesizedField "inferredType" (Type l) (Auto TypeCheck) (AST.Element l l) Sem Placed where
   synthesizedField _ _ _ _ _ = BuiltinType "SET"

instance {-# overlaps #-} (Abstract.Nameable l, Abstract.Oberon l, Ord (Abstract.QualIdent l),
                           Show (Abstract.QualIdent l),
                           Atts (Inherited (Auto TypeCheck)) (Abstract.Designator l l Sem Sem) ~ InhTC l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Expression l l Sem Sem) ~ SynTCExp l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Designator l l Sem Sem) ~ SynTCDes l) =>
                          Synthesizer (Auto TypeCheck) (AST.Designator l l) Sem Placed where
   synthesis _ (pos, AST.Variable q) InhTC{env} _ =
      SynTCDes{errors= case designatorType
                       of Nothing -> Folded [Error () pos (UnknownName q)]
                          Just{} -> mempty,
               designatorName= (,) Nothing <$> Abstract.getNonQualIdentName q
                               <|> first Just <$> Abstract.getQualIdentNames q,
               designatorType= fromMaybe UnknownType designatorType}
      where designatorType = Map.lookup q env
   synthesis _ (pos, AST.Field _record fieldName) InhTC{} (AST.Field record _fieldName) =
      SynTCDes{errors= case syn record
                       of SynTCDes{errors= Folded [],
                                   designatorType= t} ->
                             maybe (Folded [Error () pos (NonRecordType t)])
                                   (maybe (Folded [Error () pos (UnknownField fieldName t)]) $ const mempty)
                                   (access True t)
                          SynTCDes{errors= errors} -> errors,
               designatorName= Nothing,
               designatorType= fromMaybe UnknownType (fromMaybe Nothing $ access True
                                                      $ designatorType $ syn record)}
     where access _ (RecordType _ fields) = Just (Map.lookup fieldName fields)
           access True (PointerType t) = access False t
           access allowPtr (NominalType _ (Just t)) = access allowPtr t
           access allowPtr (ReceiverType t) = (receive <$>) <$> access allowPtr t
           access _ _ = Nothing
           receive (ProcedureType _ params result) = ProcedureType True params result
           receive t = t
   synthesis _ (pos, AST.Index _array index indexes) InhTC{} (AST.Index array _index _indexes) =
      SynTCDes{errors= case syn array
                       of SynTCDes{errors= Folded [],
                                   designatorType= t} -> either id (const mempty) (access True t)
                          SynTCDes{errors= errors} -> errors,
               designatorName= Nothing,
               designatorType= either (const UnknownType) id (access True $ designatorType $ syn array)}
      where access _ (ArrayType dimensions t)
              | length dimensions == length indexes + 1 = Right t
              | length dimensions == 0 && length indexes == 0 = Right t
              | otherwise = Left (Folded [Error () pos
                                          $ ExtraDimensionalIndex (length dimensions) (1 + length indexes)])
            access allowPtr (NominalType _ (Just t)) = access allowPtr t
            access allowPtr (ReceiverType t) = access allowPtr t
            access True (PointerType t) = access False t
            access _ t = Left (Folded [Error () pos (NonArrayType t)])
   synthesis _ (pos, AST.TypeGuard _designator q) InhTC{env} (AST.TypeGuard designator _q) =
      SynTCDes{errors= case (syn designator, targetType)
                                 of (SynTCDes{errors= Folded [],
                                              designatorType= t}, 
                                     Just t') -> assignmentCompatible pos t t'
                                    (SynTCDes{errors= errors}, 
                                     Nothing) -> Folded (Error () pos (UnknownName q) : getFolded errors)
                                    (SynTCDes{errors= errors}, _) -> errors,
               designatorName= Nothing,
               designatorType= fromMaybe UnknownType targetType}
      where targetType = Map.lookup q env
   synthesis _ (pos, _) InhTC{} (AST.Dereference pointer) =
      SynTCDes{errors= case syn pointer
                       of SynTCDes{errors= Folded [],
                                   designatorType= t}
                             | PointerType{} <- t -> mempty
                             | NominalType _ (Just PointerType{}) <- t -> mempty
                             | ProcedureType True _ _ <- t -> mempty
                             | otherwise -> Folded [Error () pos (NonPointerType t)]
                          SynTCDes{errors= es} -> es,
               designatorName= Nothing,
               designatorType= case designatorType (syn pointer)
                               of NominalType _ (Just (PointerType t)) -> t
                                  ProcedureType True params result -> ProcedureType False params result
                                  PointerType t -> t
                                  _ -> UnknownType}

binaryNumericOrSetSynthesis pos left right =
   SynTCExp{errors= binarySetOrNumericOperatorErrors pos (syn left) (syn right),
            inferredType= binaryNumericOperatorType (syn left) (syn right)}

binaryIntegerSynthesis pos left right =
   SynTCExp{errors= binaryIntegerOperatorErrors pos (syn left) (syn right),
            inferredType= binaryNumericOperatorType (syn left) (syn right)}

binaryBooleanSynthesis pos left right =
   SynTCExp{errors= binaryBooleanOperatorErrors pos (syn left) (syn right),
            inferredType= BuiltinType "BOOLEAN"}

unaryNumericOrSetOperatorErrors :: forall l. Abstract.Nameable l => LexicalPosition -> SynTCExp l -> Folded [Error () l]
unaryNumericOrSetOperatorErrors pos SynTCExp{errors= Folded [], inferredType= t}
   | IntegerType{} <- t = mempty
   | BuiltinType name <- t, isNumerical name || name == "SET" = mempty
   | otherwise = Folded [Error () pos (NonNumericType t)]
unaryNumericOrSetOperatorErrors _ SynTCExp{errors= errs} = errs

unaryNumericOrSetOperatorType :: (Int -> Int) -> SynTCExp l -> Type l
unaryNumericOrSetOperatorType f SynTCExp{inferredType= IntegerType x} = IntegerType (f x)
unaryNumericOrSetOperatorType _ SynTCExp{inferredType= t} = t

binarySetOrNumericOperatorErrors :: forall l. (Abstract.Nameable l, Eq (Abstract.QualIdent l))
                                 => LexicalPosition -> SynTCExp l -> SynTCExp l -> Folded [Error () l]
binarySetOrNumericOperatorErrors _
  SynTCExp{errors= Folded [], inferredType= BuiltinType name1}
  SynTCExp{errors= Folded [], inferredType= BuiltinType name2}
  | isNumerical name1 && isNumerical name2 || name1 == "SET" && name2 == "SET" = mempty
binarySetOrNumericOperatorErrors _
  SynTCExp{errors= Folded [], inferredType= IntegerType{}}
  SynTCExp{errors= Folded [], inferredType= BuiltinType name}
  | isNumerical name = mempty
binarySetOrNumericOperatorErrors _
  SynTCExp{errors= Folded [], inferredType= BuiltinType name}
  SynTCExp{errors= Folded [], inferredType= IntegerType{}}
  | isNumerical name = mempty
binarySetOrNumericOperatorErrors _
  SynTCExp{errors= Folded [], inferredType= IntegerType{}}
  SynTCExp{errors= Folded [], inferredType= IntegerType{}} = mempty
binarySetOrNumericOperatorErrors pos SynTCExp{errors= Folded [], inferredType= t1}
                                     SynTCExp{errors= Folded [], inferredType= t2}
  | t1 == t2 = Folded [Error () pos (NonNumericType t1)]
  | otherwise = Folded [Error () pos (TypeMismatch t1 t2)]
binarySetOrNumericOperatorErrors _ SynTCExp{errors= errs1} SynTCExp{errors= errs2} = errs1 <> errs2

binaryNumericOperatorType :: (Abstract.Nameable l, Eq (Abstract.QualIdent l)) => SynTCExp l -> SynTCExp l -> Type l
binaryNumericOperatorType SynTCExp{inferredType= t1} SynTCExp{inferredType= t2}
  | t1 == t2 = t1
  | IntegerType{} <- t1 = t2
  | IntegerType{} <- t2 = t1
  | BuiltinType name1 <- t1, BuiltinType name2 <- t2,
    Just index1 <- List.elemIndex name1 numericTypeNames,
    Just index2 <- List.elemIndex name2 numericTypeNames = BuiltinType (numericTypeNames !! max index1 index2)
  | otherwise = t1

binaryIntegerOperatorErrors :: Abstract.Nameable l =>
                               LexicalPosition ->  SynTCExp l -> SynTCExp l -> Folded [Error () l]
binaryIntegerOperatorErrors pos syn1 syn2 = integerExpressionErrors pos syn1 <> integerExpressionErrors pos syn2

integerExpressionErrors :: forall l. LexicalPosition -> SynTCExp l -> Folded [Error () l]
integerExpressionErrors pos SynTCExp{errors= Folded [], inferredType= t}
  | isIntegerType t = mempty
  | otherwise = Folded [Error () pos (NonIntegerType t)]
integerExpressionErrors _ SynTCExp{errors= errs} = errs

isIntegerType IntegerType{} = True
isIntegerType (BuiltinType "SHORTINT") = True
isIntegerType (BuiltinType "INTEGER") = True
isIntegerType (BuiltinType "LONGINT") = True
isIntegerType t = False

booleanExpressionErrors :: forall l. LexicalPosition -> SynTCExp l -> Folded [Error () l]
booleanExpressionErrors _ SynTCExp{errors= Folded [],
                                     inferredType= BuiltinType "BOOLEAN"} = mempty
booleanExpressionErrors pos SynTCExp{errors= Folded [], inferredType= t} = 
   Folded [Error () pos (NonBooleanType t)]
booleanExpressionErrors _ SynTCExp{errors= errs} = errs

binaryBooleanOperatorErrors :: forall l. (Abstract.Nameable l, Eq (Abstract.QualIdent l))
                            => LexicalPosition -> SynTCExp l -> SynTCExp l -> Folded [Error () l]
binaryBooleanOperatorErrors _pos
  SynTCExp{errors= Folded [], inferredType= BuiltinType "BOOLEAN"}
  SynTCExp{errors= Folded [], inferredType= BuiltinType "BOOLEAN"} = mempty
binaryBooleanOperatorErrors pos
  SynTCExp{errors= Folded [], inferredType= t1}
  SynTCExp{errors= Folded [], inferredType= t2}
  | t1 == t2 = Folded [Error () pos (NonBooleanType t1)]
  | otherwise = Folded [Error () pos (TypeMismatch t1 t2)]
binaryBooleanOperatorErrors _ SynTCExp{errors= errs1} SynTCExp{errors= errs2} = errs1 <> errs2

parameterCompatible :: forall l. (Abstract.Nameable l, Eq (Abstract.QualIdent l))
                    => LexicalPosition -> (Bool, Type l) -> Type l -> Folded [Error () l]
parameterCompatible _ (_, expected@(ArrayType [] _)) actual
  | arrayCompatible expected actual = mempty
parameterCompatible pos (True, expected) actual
  | expected == actual = mempty
  | otherwise = Folded [Error () pos (UnequalTypes expected actual)]
parameterCompatible pos (False, expected) actual
  | BuiltinType "ARRAY" <- expected, ArrayType{} <- actual = mempty
  | otherwise = assignmentCompatible pos expected actual

assignmentCompatibleIn :: forall l. (Abstract.Nameable l, Eq (Abstract.QualIdent l))
                       => InhTCExp l -> LexicalPosition -> Type l -> Folded [Error () l]
assignmentCompatibleIn InhTCExp{expectedType} pos = assignmentCompatible pos expectedType

assignmentCompatible :: forall l. (Abstract.Nameable l, Eq (Abstract.QualIdent l))
                     => LexicalPosition -> Type l -> Type l -> Folded [Error () l]
assignmentCompatible pos expected actual
   | expected == actual = mempty
   | BuiltinType name1 <- expected, BuiltinType name2 <- actual,
     Just index1 <- List.elemIndex name1 numericTypeNames,
     Just index2 <- List.elemIndex name2 numericTypeNames, 
     index1 >= index2 = mempty
   | BuiltinType name <- expected, IntegerType{} <- actual, isNumerical name = mempty
   | BuiltinType "BASIC TYPE" <- expected, BuiltinType name <- actual,
     name `elem` ["BOOLEAN", "CHAR", "SHORTINT", "INTEGER", "LONGINT", "REAL", "LONGREAL", "SET"] = mempty
   | BuiltinType "POINTER" <- expected, PointerType{} <- actual = mempty
   | BuiltinType "POINTER" <- expected, NominalType _ (Just t) <- actual =
       assignmentCompatible pos expected t
   | BuiltinType "CHAR" <- expected, actual == StringType 1 = mempty
   | ReceiverType t <- actual = assignmentCompatible pos expected t
   | ReceiverType t <- expected = assignmentCompatible pos t actual
   | NilType <- actual, PointerType{} <- expected = mempty
   | NilType <- actual, ProcedureType{} <- expected = mempty
   | NilType <- actual, NominalType _ (Just t) <- expected = assignmentCompatible pos t actual
--   | ArrayType [] (BuiltinType "CHAR") <- expected, StringType{} <- actual = mempty
   | ArrayType [m] (BuiltinType "CHAR") <- expected, StringType n <- actual =
       Folded (if m < n then [Error () pos (TooSmallArrayType m n)] else [])
   | targetExtends actual expected = mempty
   | NominalType _ (Just t) <- expected, ProcedureType{} <- actual = assignmentCompatible pos t actual
   | otherwise = Folded [Error () pos (IncompatibleTypes expected actual)]

arrayCompatible (ArrayType [] t1) (ArrayType _ t2) = t1 == t2 || arrayCompatible t1 t2
arrayCompatible (ArrayType [] (BuiltinType "CHAR")) StringType{} = True
arrayCompatible (NominalType _ (Just t1)) t2 = arrayCompatible t1 t2
arrayCompatible t1 (NominalType _ (Just t2)) = arrayCompatible t1 t2
arrayCompatible _ _ = False

extends, targetExtends :: Eq (Abstract.QualIdent l) => Type l -> Type l -> Bool
t1 `extends` t2 | t1 == t2 = True
RecordType ancestry _ `extends` NominalType q _ = q `elem` ancestry
NominalType _ (Just t1) `extends` t2 = t1 `extends` t2
t1 `extends` t2 = False -- error (show (t1, t2))

ultimate :: Type l -> Type l
ultimate (NominalType _ (Just t)) = ultimate t
ultimate t = t

isNumerical t = t `elem` numericTypeNames
numericTypeNames = ["SHORTINT", "INTEGER", "LONGINT", "REAL", "LONGREAL"]

PointerType t1 `targetExtends` PointerType t2 = t1 `extends` t2
NominalType _ (Just t1) `targetExtends` t2 = t1 `targetExtends` t2
t1 `targetExtends` NominalType _ (Just t2) = t1 `targetExtends` t2
t1 `targetExtends` t2 | t1 == t2 = True
t1 `targetExtends` t2 = False

instance Transformation.Transformation (Auto TypeCheck) where
   type Domain (Auto TypeCheck) = Placed
   type Codomain (Auto TypeCheck) = Semantics (Auto TypeCheck)

instance AG.Revelation (Auto TypeCheck) where
   reveal (Auto TypeCheck) = snd

instance Ord (Abstract.QualIdent l) => Transformation.At (Auto TypeCheck) (Modules l Sem Sem) where
   ($) = AG.applyDefault snd

-- * Unsafe Rank2 AST instances

instance Rank2.Apply (AST.Module l l f') where
   AST.Module name1 imports1 body1 <*> ~(AST.Module name2 imports2 body2) =
      AST.Module name1 imports1 (Rank2.apply body1 body2)

-- | Check if the given collection of modules is well typed and return all type errors found. The collection is a
-- 'Map' keyed by module name. The first argument's value is typically 'predefined' or 'predefined2'.
checkModules :: forall l. (Abstract.Oberon l, Abstract.Nameable l,
                           Ord (Abstract.QualIdent l), Show (Abstract.QualIdent l),
                           Atts (Inherited (Auto TypeCheck)) (Abstract.Block l l Sem Sem) ~ InhTC l,
                           Atts (Synthesized (Auto TypeCheck)) (Abstract.Block l l Sem Sem) ~ SynTCMod l,
                           Full.Functor (Auto TypeCheck) (Abstract.Block l l))
             => Environment l -> Map AST.Ident (Placed (AST.Module l l Placed Placed)) -> [Error AST.Ident l]
checkModules predef modules =
   getFolded (errors (syn (Transformation.apply (Auto TypeCheck) (wrap $ Auto TypeCheck Deep.<$> Modules modules)
                           `Rank2.apply`
                           Inherited (InhTCRoot predef)) :: SynTCMods l))
   where wrap = (,) (0, Trailing [], 0)

predefined, predefined2 :: (Abstract.Wirthy l, Ord (Abstract.QualIdent l)) => Environment l
-- | The set of 'Predefined' types and procedures defined in the Oberon Language Report.
predefined = Map.fromList $ map (first Abstract.nonQualIdent) $
   [("BOOLEAN", BuiltinType "BOOLEAN"),
    ("CHAR", BuiltinType "CHAR"),
    ("SHORTINT", BuiltinType "SHORTINT"),
    ("INTEGER", BuiltinType "INTEGER"),
    ("LONGINT", BuiltinType "LONGINT"),
    ("REAL", BuiltinType "REAL"),
    ("LONGREAL", BuiltinType "LONGREAL"),
    ("SET", BuiltinType "SET"),
    ("TRUE", BuiltinType "BOOLEAN"),
    ("FALSE", BuiltinType "BOOLEAN"),
    ("ABS", ProcedureType False [(False, BuiltinType "INTEGER")] $ Just $ BuiltinType "INTEGER"),
    ("ASH", ProcedureType False [(False, BuiltinType "INTEGER")] $ Just $ BuiltinType "INTEGER"),
    ("CAP", ProcedureType False [(False, BuiltinType "CHAR")] $ Just $ BuiltinType "CHAR"),
    ("LEN", ProcedureType False [(False, BuiltinType "ARRAY")] $ Just $ BuiltinType "LONGINT"),
    ("MAX", ProcedureType False [(False, BuiltinType "BASIC TYPE")] $ Just UnknownType),
    ("MIN", ProcedureType False [(False, BuiltinType "BASIC TYPE")] $ Just UnknownType),
    ("ODD", ProcedureType False [(False, BuiltinType "CHAR")] $ Just $ BuiltinType "BOOLEAN"),
    ("SIZE", ProcedureType False [(False, BuiltinType "CHAR")] $ Just $ BuiltinType "INTEGER"),
    ("ORD", ProcedureType False [(False, BuiltinType "CHAR")] $ Just $ BuiltinType "INTEGER"),
    ("CHR", ProcedureType False [(False, BuiltinType "LONGINT")] $ Just $ BuiltinType "CHAR"),
    ("SHORT", ProcedureType False [(False, BuiltinType "LONGINT")] $ Just $ BuiltinType "SHORTINT"),
    ("LONG", ProcedureType False [(False, BuiltinType "INTEGER")] $ Just $ BuiltinType "INTEGER"),
    ("ENTIER", ProcedureType False [(False, BuiltinType "REAL")] $ Just $ BuiltinType "INTEGER"),
    ("INC", ProcedureType False [(False, BuiltinType "LONGINT")] Nothing),
    ("DEC", ProcedureType False [(False, BuiltinType "LONGINT")] Nothing),
    ("INCL", ProcedureType False [(False, BuiltinType "SET"), (False, BuiltinType "INTEGER")] Nothing),
    ("EXCL", ProcedureType False [(False, BuiltinType "SET"), (False, BuiltinType "INTEGER")] Nothing),
    ("COPY", ProcedureType False [(False, BuiltinType "ARRAY"), (False, BuiltinType "ARRAY")] Nothing),
    ("NEW", ProcedureType False [(False, BuiltinType "POINTER")] Nothing),
    ("HALT", ProcedureType False [(False, BuiltinType "INTEGER")] Nothing)]

-- | The set of 'Predefined' types and procedures defined in the Oberon-2 Language Report.
predefined2 = predefined <>
   Map.fromList (first Abstract.nonQualIdent <$>
                 [("ASSERT", ProcedureType False [(False, BuiltinType "BOOLEAN"),
                                                  (False, BuiltinType "INTEGER")] Nothing)])

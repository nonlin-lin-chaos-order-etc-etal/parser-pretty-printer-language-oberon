{-# LANGUAGE FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings, RankNTypes,
             ScopedTypeVariables, TemplateHaskell, TypeFamilies, UndecidableInstances #-}

module Language.Oberon.ConstantFolder where

import Control.Applicative (liftA2, (<|>))
import Control.Arrow (first)
import Control.Monad (join)
import Data.Char (chr)
import Data.Coerce (coerce)
import Data.Foldable (toList)
import Data.Functor.Identity (Identity(..))
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.List as List
import Data.Maybe (fromMaybe)
import Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as Map
import Data.Semigroup (Semigroup(..), sconcat)
import qualified Data.Text as Text

import qualified Rank2
import qualified Rank2.TH
import qualified Transformation as Shallow
import qualified Transformation.Deep as Deep
import qualified Transformation.Full as Full
import qualified Transformation.AG as AG
import qualified Transformation.Rank2
import Transformation.AG (Attribution(..), Atts, Inherited(..), Synthesized(..), Semantics)

import qualified Language.Oberon.Abstract as Abstract
import qualified Language.Oberon.AST as AST

import Debug.Trace

foldConstants :: (Abstract.Oberon l, Abstract.Nameable l,
                  Ord (Abstract.QualIdent l), Show (Abstract.QualIdent l),
                  Atts (Inherited ConstantFold)
                  (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
                  ~ InhCF l,
                  Atts (Inherited ConstantFold)
                       (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
                  ~ InhCF l,
                  Atts (Synthesized ConstantFold)
                       (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
                  ~ SynCFMod' l (Abstract.Declaration l l),
                  Atts (Synthesized ConstantFold)
                       (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
                  ~ SynCF' (Abstract.StatementSequence l l),
                  Full.Functor ConstantFold (Abstract.Declaration l l) Placed (Semantics ConstantFold),
                  Full.Functor ConstantFold (Abstract.StatementSequence l l) Placed (Semantics ConstantFold),
                  Deep.Functor ConstantFold (Abstract.Declaration l l) Placed (Semantics ConstantFold),
                  Deep.Functor ConstantFold (Abstract.StatementSequence l l) Placed (Semantics ConstantFold))
              => Environment l -> Map AST.Ident (AST.Module l l Placed Placed)
              -> Map AST.Ident (AST.Module l l Placed Placed)
foldConstants predef modules =
   runIdentity <$>
   getModules (modulesFolded $
               syn (ConstantFold Shallow.<$> (0, ConstantFold Deep.<$> Modules modules')
                    `Rank2.apply`
                    Inherited (InhCFRoot predef)))
   where modules' = ((,) 0) <$> modules

type Environment l = Map (Abstract.QualIdent l) (Abstract.Expression l l ((,) Int) ((,) Int))

newtype Modules l f' f = Modules {getModules :: Map AST.Ident (f (AST.Module l l f' f'))}

data ConstantFold = ConstantFold

data ConstantFoldSyn l = ConstantFoldSyn (InhCF l)
data ConstantFoldInh l = ConstantFoldInh (InhCF l)

instance (Atts (Synthesized ConstantFold) (f ((,) Int) ((,) Int)) ~ SynCF' f,
          Atts (Inherited ConstantFold) (f ((,) Int) ((,) Int)) ~ InhCF l) =>
         Shallow.Functor (ConstantFoldSyn l) (Semantics ConstantFold) ((,) Int)
                         (f ((,) Int) ((,) Int)) where
   ConstantFoldSyn inh <$> f = folded (syn $ Rank2.apply f $ Inherited inh)

data InhCFRoot l = InhCFRoot{rootEnv :: Environment l}

data InhCF l = InhCF{env           :: Environment l,
                     currentModule :: AST.Ident}

data SynCF a = SynCF{folded :: (Int, a)}

data SynCFMod l a = SynCFMod{moduleEnv    :: Environment l,
                             moduleFolded :: (Int, a)}

data SynCFExp l = SynCFExp{foldedExp   :: (Int, AST.Expression l l ((,) Int) ((,) Int)),
                           foldedValue :: Maybe (AST.Value l l ((,) Int) ((,) Int))}

data SynCFRoot a = SynCFRoot{modulesFolded :: a}

-- * Modules instances, TH candidates
instance (Functor p, Deep.Functor t (AST.Module l l) p q, Shallow.Functor t p q (AST.Module l l q q)) =>
         Deep.Functor t (Modules l) p q where
   t <$> ~(Modules ms) = Modules (mapModule <$> ms)
      where mapModule m = t Shallow.<$> ((t Deep.<$>) <$> m)

instance Rank2.Functor (Modules l f') where
   f <$> ~(Modules ms) = Modules (f <$> ms)

instance Rank2.Apply (Modules l f') where
   ~(Modules fs) <*> ~(Modules ms) = Modules (Map.intersectionWith Rank2.apply fs ms)

-- * Boring attribute types
type instance Atts (Synthesized ConstantFold) (Modules l f' f) = SynCFRoot (Modules l ((,) Int) Identity)
type instance Atts (Synthesized ConstantFold) (AST.Module l l f' f) = SynCFMod' l (AST.Module l l)
type instance Atts (Synthesized ConstantFold) (AST.Declaration l l f' f) = SynCFMod' l (AST.Declaration l l)
type instance Atts (Synthesized ConstantFold) (AST.ProcedureHeading l l f' f) = SynCF' (AST.ProcedureHeading l l)
type instance Atts (Synthesized ConstantFold) (AST.Block l l f' f) = SynCF' (AST.Block l l)
type instance Atts (Synthesized ConstantFold) (AST.FormalParameters l l f' f) = SynCF' (AST.FormalParameters l l)
type instance Atts (Synthesized ConstantFold) (AST.FPSection l l f' f) = SynCF' (AST.FPSection l l)
type instance Atts (Synthesized ConstantFold) (AST.Type l l f' f) = SynCF' (AST.Type l l)
type instance Atts (Synthesized ConstantFold) (AST.FieldList l l f' f) = SynCF' (AST.FieldList l l)
type instance Atts (Synthesized ConstantFold) (AST.StatementSequence l l f' f) = SynCF' (AST.StatementSequence l l)
type instance Atts (Synthesized ConstantFold) (AST.Expression l l f' f) = SynCFExp l
type instance Atts (Synthesized ConstantFold) (AST.Element l l f' f) = SynCF' (AST.Element l l)
type instance Atts (Synthesized ConstantFold) (AST.Value l l f' f) = SynCF' (AST.Value l l)
type instance Atts (Synthesized ConstantFold) (AST.Designator l l f' f) =
   SynCF (AST.Designator l l ((,) Int) ((,) Int), Maybe (AST.Expression l l ((,) Int) ((,) Int)))
type instance Atts (Synthesized ConstantFold) (Deep.Product (AST.Expression l l) (AST.StatementSequence l l) f' f) =
   SynCF' (Deep.Product (AST.Expression l l) (AST.StatementSequence l l))
type instance Atts (Synthesized ConstantFold) (AST.Statement l l f' f) = SynCF' (AST.Statement l l)
type instance Atts (Synthesized ConstantFold) (AST.Case l l f' f) = SynCF' (AST.Case l l)
type instance Atts (Synthesized ConstantFold) (AST.CaseLabels l l f' f) = SynCF' (AST.CaseLabels l l)
type instance Atts (Synthesized ConstantFold) (AST.WithAlternative l l f' f) = SynCF' (AST.WithAlternative l l)

type instance Atts (Inherited ConstantFold) (Modules l f' f) = InhCFRoot l
type instance Atts (Inherited ConstantFold) (AST.Module l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Declaration l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.ProcedureHeading l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Block l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.FormalParameters l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.FPSection l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Type l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.FieldList l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.StatementSequence l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Expression l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Element l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Value l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Designator l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (Deep.Product (AST.Expression l l) (AST.StatementSequence l l) f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Statement l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.Case l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.CaseLabels l l f' f) = InhCF l
type instance Atts (Inherited ConstantFold) (AST.WithAlternative l l f' f) = InhCF l

type SynCF' node = SynCF (node ((,) Int) ((,) Int))
type SynCFMod' l node = SynCFMod l (node ((,) Int) ((,) Int))

-- * Rules

instance Ord (Abstract.QualIdent l) =>
         Attribution ConstantFold (Modules l) (Int, Modules l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (_, Modules self) (Inherited inheritance, Modules ms) =
     (Synthesized SynCFRoot{modulesFolded= Modules (pure . snd . moduleFolded . syn <$> ms)},
      Modules (Map.mapWithKey moduleInheritance self))
     where moduleInheritance name mod = Inherited InhCF{env= rootEnv inheritance <> foldMap (moduleEnv . syn) ms,
                                                        currentModule= name}

instance (Abstract.Oberon l, Abstract.Nameable l, Ord (Abstract.QualIdent l), Show (Abstract.QualIdent l),
          Atts (Synthesized ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFMod' l (Abstract.Declaration l l),
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Attribution ConstantFold (AST.Module l l) (Int, AST.Module l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (_, AST.Module moduleName imports decls body) 
               (Inherited inheritance, AST.Module _ _ decls' body') =
      (Synthesized SynCFMod{moduleEnv= exportedEnv,
                            moduleFolded= (0, AST.Module moduleName imports (moduleFolded . syn <$> decls') (folded . syn <$> body'))},
       AST.Module moduleName imports (pure $ Inherited localEnv) (pure $ Inherited localEnv))
      where exportedEnv = Map.mapKeysMonotonic export newEnv
            newEnv = Map.unions (moduleEnv . syn <$> decls')
            localEnv = InhCF (newEnv `Map.union` env inheritance) (currentModule inheritance)
            export q
               | Just name <- Abstract.getNonQualIdentName q = Abstract.qualIdent moduleName name
               | otherwise = q

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l), Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Block l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.ProcedureHeading l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFMod' l (Abstract.Declaration l l),
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l),
          Atts (Synthesized ConstantFold) (Abstract.ProcedureHeading l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.ProcedureHeading l l),
          Atts (Synthesized ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FormalParameters l l),
          Atts (Synthesized ConstantFold) (Abstract.Block l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Block l l),
          Atts (Synthesized ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Attribution ConstantFold (AST.Declaration l l)
                     (Int, AST.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.ConstantDeclaration namedef _)
               (Inherited inheritance, AST.ConstantDeclaration _ expression) =
      (Synthesized SynCFMod{moduleEnv= Map.singleton (Abstract.nonQualIdent name) (snd $ foldedExp $ syn expression),
                            moduleFolded = (pos, AST.ConstantDeclaration namedef (foldedExp $ syn expression))},
       AST.ConstantDeclaration namedef (Inherited inheritance))
      where name = Abstract.getIdentDefName namedef
   attribution ConstantFold (pos, AST.TypeDeclaration namedef _)
               (Inherited inheritance, AST.TypeDeclaration _ definition) =
      (Synthesized SynCFMod{moduleEnv= mempty,
                            moduleFolded = (pos, AST.TypeDeclaration namedef (folded $ syn definition))},
       AST.TypeDeclaration namedef (Inherited inheritance))
   attribution ConstantFold (pos, AST.VariableDeclaration names _declaredType)
               (Inherited inheritance, AST.VariableDeclaration _names declaredType) =
      (Synthesized SynCFMod{moduleEnv= mempty,
                            moduleFolded= (pos, AST.VariableDeclaration names (folded $ syn declaredType))},
       AST.VariableDeclaration names (Inherited inheritance))
   attribution ConstantFold (pos, AST.ProcedureDeclaration _heading _body)
               (Inherited inheritance, AST.ProcedureDeclaration heading body) =
      (Synthesized SynCFMod{moduleEnv= mempty,
                            moduleFolded= (pos, AST.ProcedureDeclaration (folded $ syn heading) (folded $ syn body))},
       AST.ProcedureDeclaration (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, AST.ForwardDeclaration namedef _signature)
               (Inherited inheritance, AST.ForwardDeclaration _namedef signature) =
      (Synthesized SynCFMod{moduleEnv= mempty,
                            moduleFolded= (pos, AST.ForwardDeclaration namedef (folded . syn <$> signature))},
       AST.ForwardDeclaration namedef (Just (Inherited inheritance)))

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FormalParameters l l)) =>
         Attribution ConstantFold (AST.ProcedureHeading l l)
                     (Int, AST.ProcedureHeading l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.ProcedureHeading indirect namedef _signature)
      (Inherited inheritance, AST.ProcedureHeading _indirect _ signature) =
      (Synthesized SynCF{folded= (pos, AST.ProcedureHeading indirect namedef (folded . syn <$> signature))},
       AST.ProcedureHeading indirect namedef (Just $ Inherited inheritance))
   attribution ConstantFold (pos, AST.TypeBoundHeading var receiverName receiverType indirect namedef _signature)
      (Inherited inheritance, AST.TypeBoundHeading _var _name _type _indirect _ signature) =
      (Synthesized SynCF{folded= (pos, AST.TypeBoundHeading var receiverName receiverType indirect namedef (folded . syn <$> signature))},
       AST.TypeBoundHeading var receiverName receiverType indirect namedef (Just $ Inherited inheritance))

instance (Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFMod' l (Abstract.Declaration l l),
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Attribution ConstantFold (AST.Block l l) (Int, AST.Block l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.Block{}) (Inherited inheritance, AST.Block declarations statements) =
      (Synthesized SynCF{folded= (pos, AST.Block (moduleFolded . syn <$> declarations) (folded . syn <$> statements))},
       AST.Block (pure $ Inherited localInherited) (pure $ Inherited localInherited))
      where localInherited = InhCF (foldMap (moduleEnv . syn) declarations <> env inheritance)
                                   (currentModule inheritance)
            
instance (Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.FPSection l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.FPSection l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FPSection l l)) =>
         Attribution ConstantFold (AST.FormalParameters l l)
         (Int, AST.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.FormalParameters _sections returnType)
               (Inherited inheritance, AST.FormalParameters sections _returnType) =
      (Synthesized SynCF{folded= (pos, AST.FormalParameters (folded . syn <$> sections) returnType)},
       AST.FormalParameters (pure $ Inherited inheritance) returnType)

instance (Abstract.Wirthy l, Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l)) =>
         Attribution ConstantFold (AST.FPSection l l) (Int, AST.FPSection l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.FPSection var names _typeDef) (Inherited inheritance, AST.FPSection _var _names typeDef) =
      (Synthesized SynCF{folded= (pos, AST.FPSection var names (folded $ syn typeDef))},
       AST.FPSection var names (Inherited inheritance))

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l), Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.FieldList l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FormalParameters l l),
          Atts (Synthesized ConstantFold) (Abstract.FieldList l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FieldList l l),
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l),
          Atts (Synthesized ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Attribution ConstantFold (AST.Type l l) (Int, AST.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.TypeReference q) (Inherited inheritance, _) = 
      (Synthesized SynCF{folded= (pos, AST.TypeReference q)},
       AST.TypeReference q)
   attribution ConstantFold (pos, AST.ArrayType _dimensions _itemType) (Inherited inheritance, AST.ArrayType dimensions itemType) = 
      (Synthesized SynCF{folded= (pos, AST.ArrayType (foldedExp . syn <$> dimensions) (folded $ syn itemType))},
       AST.ArrayType [Inherited inheritance] (Inherited inheritance))
   attribution ConstantFold (pos, AST.RecordType base _fields) (Inherited inheritance, AST.RecordType _base fields) =
      (Synthesized SynCF{folded= (pos, AST.RecordType base (folded . syn <$> fields))},
       AST.RecordType base (pure $ Inherited inheritance))
   attribution ConstantFold (pos, _self) (Inherited inheritance, AST.PointerType targetType) =
      (Synthesized SynCF{folded= (pos, AST.PointerType (folded $ syn targetType))},
       AST.PointerType (Inherited inheritance))
   attribution ConstantFold (pos, AST.ProcedureType _signature) (Inherited inheritance, AST.ProcedureType signature) = 
      (Synthesized SynCF{folded= (pos, AST.ProcedureType (folded . syn <$> signature))},
       AST.ProcedureType (Inherited inheritance <$ signature))

instance (Abstract.Nameable l,
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l)) =>
         Attribution ConstantFold (AST.FieldList l l)
                     (Int, AST.FieldList l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.FieldList names _declaredType) (Inherited inheritance, AST.FieldList _names declaredType) =
      (Synthesized SynCF{folded= (pos, AST.FieldList names (folded $ syn declaredType))},
       AST.FieldList names (Inherited inheritance))
   attribution ConstantFold (pos, _self) (Inherited inheritance, AST.EmptyFieldList) =
      (Synthesized SynCF{folded= (pos, AST.EmptyFieldList)}, AST.EmptyFieldList)

instance (Abstract.Nameable l, Abstract.Expression l ~ AST.Expression l) =>
         Attribution ConstantFold (Deep.Product (AST.Expression l l) (AST.StatementSequence l l))
                     (Int, Deep.Product (AST.Expression l l) (AST.StatementSequence l l)
                                        (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, _) (Inherited inheritance, Deep.Pair condition statements) =
      (Synthesized SynCF{folded= (pos, Deep.Pair (foldedExp $ syn condition) (folded $ syn statements))},
       Deep.Pair (Inherited inheritance) (Inherited inheritance))

instance (Atts (Inherited ConstantFold) (Abstract.Statement l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Statement l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Statement l l)) =>
         Attribution ConstantFold (AST.StatementSequence l l)
                     (Int, AST.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.StatementSequence _statements) (Inherited inheritance, AST.StatementSequence statements) =
      (Synthesized SynCF{folded= (pos, AST.StatementSequence (folded . syn <$> statements))},
       AST.StatementSequence (pure $ Inherited inheritance))

instance (Abstract.Wirthy l, Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Deep.Product (Abstract.Expression l l) (Abstract.StatementSequence l l)
                                      (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Case l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.WithAlternative l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l),
          Atts (Synthesized ConstantFold) (Deep.Product (Abstract.Expression l l) (Abstract.StatementSequence l l)
                                        (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Deep.Product (Abstract.Expression l l) (Abstract.StatementSequence l l)),
          Atts (Synthesized ConstantFold) (Abstract.Case l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Case l l),
          Atts (Synthesized ConstantFold) (Abstract.WithAlternative l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.WithAlternative l l),
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l,
          Atts (Synthesized ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF (Abstract.Designator l l ((,) Int) ((,) Int), Maybe (Abstract.Expression l l ((,) Int) ((,) Int)))) =>
         Attribution ConstantFold (AST.Statement l l) (Int, AST.Statement l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, self) (Inherited inheritance, AST.Assignment lhs rhs) =
      (Synthesized SynCF{folded= (pos, AST.Assignment (fst <$> folded (syn lhs)) (foldedExp $ syn rhs))},
       AST.Assignment (Inherited inheritance) (Inherited inheritance))

instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Attribution ConstantFold (AST.WithAlternative l l)
                     (Int, AST.WithAlternative l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.WithAlternative var subtype _body)
                         (Inherited inheritance, AST.WithAlternative _var _subtype body) =
      (Synthesized SynCF{folded= (pos, AST.WithAlternative var subtype (folded $ syn body))},
       AST.WithAlternative var subtype (Inherited inheritance))

instance (Atts (Inherited ConstantFold) (Abstract.CaseLabels l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.CaseLabels l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.CaseLabels l l),
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Attribution ConstantFold (AST.Case l l) (Int, AST.Case l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, _self) (Inherited inheritance, AST.Case labels body) =
      (Synthesized SynCF{folded= (pos, AST.Case (folded . syn <$> labels) (folded $ syn body))},
       AST.Case (pure $ Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _self) (Inherited inheritance, AST.EmptyCase) =
      (Synthesized SynCF{folded= (pos, AST.EmptyCase)}, AST.EmptyCase)

instance (Abstract.Nameable l, Eq (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Attribution ConstantFold (AST.CaseLabels l l) (Int, AST.CaseLabels l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.SingleLabel value) =
      (Synthesized SynCF{folded= (pos, AST.SingleLabel (foldedExp $ syn value))},
       AST.SingleLabel (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.LabelRange start end) =
      (Synthesized SynCF{folded= (pos, AST.LabelRange (foldedExp $ syn start) (foldedExp $ syn end))},
       AST.LabelRange (Inherited inheritance) (Inherited inheritance))

instance (Abstract.CoWirthy l, Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l, Abstract.Value l ~ AST.Value l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Element l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l,
          Atts (Synthesized ConstantFold) (Abstract.Element l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Element l l),
          Atts (Synthesized ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF (Abstract.Designator l l ((,) Int) ((,) Int), Maybe (Abstract.Expression l l ((,) Int) ((,) Int)))) =>
         Attribution ConstantFold (AST.Expression l l)
                     (Int, AST.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.Relation op _ _) (Inherited inheritance, AST.Relation _op left right) =
      (Synthesized $ case join (compareValues <$> foldedValue (syn left) <*> foldedValue (syn right))
                     of Just value -> SynCFExp{foldedExp= (pos, Abstract.literal (pos, value)),
                                               foldedValue= Just value}
                        Nothing -> SynCFExp{foldedExp= (pos, AST.Relation op (foldedExp $ syn left) (foldedExp $ syn right)),
                                            foldedValue= Nothing},
       AST.Relation op (Inherited inheritance) (Inherited inheritance))
      where (leftPos, leftExp) = foldedExp (syn left)
            compareValues (AST.Boolean l) (AST.Boolean r)   = relate op (compare l r)
            compareValues (AST.Integer l) (AST.Integer r)   = relate op (compare l r)
            compareValues (AST.Real l) (AST.Real r)         = relate op (compare l r)
            compareValues (AST.Integer l) (AST.Real r)      = relate op (compare (fromIntegral l) r)
            compareValues (AST.Real l) (AST.Integer r)      = relate op (compare l (fromIntegral r))
            compareValues (AST.CharCode l) (AST.CharCode r) = relate op (compare l r)
            compareValues (AST.String l) (AST.String r)     = relate op (compare l r)
            compareValues (AST.CharCode l) (AST.String r)   = relate op (compare (Text.singleton $ chr l) r)
            compareValues (AST.String l) (AST.CharCode r)   = relate op (compare l (Text.singleton $ chr r))
            compareValues _ _                               = Nothing
            relate Abstract.Equal EQ          = Just Abstract.true
            relate Abstract.Equal _           = Just Abstract.false
            relate Abstract.Unequal EQ        = Just Abstract.false
            relate Abstract.Unequal _         = Just Abstract.true
            relate Abstract.Less LT           = Just Abstract.true
            relate Abstract.Less _            = Just Abstract.false
            relate Abstract.LessOrEqual GT    = Just Abstract.false
            relate Abstract.LessOrEqual _     = Just Abstract.true
            relate Abstract.Greater GT        = Just Abstract.true
            relate Abstract.Greater _         = Just Abstract.false
            relate Abstract.GreaterOrEqual LT = Just Abstract.false
            relate Abstract.GreaterOrEqual _  = Just Abstract.true
            relate Abstract.In _              = Nothing
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Positive expr) =
      (Synthesized $ case foldedValue (syn expr)
                     of Just (AST.Integer n) -> SynCFExp{foldedExp= (pos, AST.Literal (pos, AST.Integer n)),
                                                         foldedValue= Just (AST.Integer n)}
                        Just (AST.Real n) -> SynCFExp{foldedExp= (pos, AST.Literal (pos, AST.Real n)),
                                                      foldedValue= Just (AST.Real n)}
                        _ -> SynCFExp{foldedExp= (pos, AST.Positive $ foldedExp $ syn expr),
                                      foldedValue= Nothing},
       AST.Positive (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Negative expr) =
      (Synthesized $ case foldedValue (syn expr)
                     of Just (AST.Integer n) -> SynCFExp{foldedExp= (pos, AST.Literal (pos, AST.Integer $ negate n)),
                                                         foldedValue= Just (AST.Integer $ negate n)}
                        Just (AST.Real n) -> SynCFExp{foldedExp= (pos, AST.Literal (pos, AST.Real $ negate n)),
                                                      foldedValue= Just (AST.Real $ negate n)}
                        _ -> SynCFExp{foldedExp= (pos, AST.Negative $ foldedExp $ syn expr),
                                      foldedValue= Nothing},
       AST.Negative (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Add left right) =
      (Synthesized $ foldBinaryArithmetic pos AST.Add (+) (syn left) (syn right),
       AST.Add (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Subtract left right) =
      (Synthesized $ foldBinaryArithmetic pos AST.Subtract (-) (syn left) (syn right),
       AST.Subtract (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Or left right) =
      (Synthesized $ foldBinaryBoolean pos AST.Or (||) (syn left) (syn right),
       AST.Or (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Multiply left right) =
      (Synthesized $ foldBinaryArithmetic pos AST.Multiply (*) (syn left) (syn right),
       AST.Multiply (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Divide left right) =
      (Synthesized $ foldBinaryFractional pos AST.Divide (/) (syn left) (syn right),
       AST.Divide (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.IntegerDivide left right) =
      (Synthesized $ foldBinaryInteger pos AST.IntegerDivide div (syn left) (syn right),
       AST.IntegerDivide (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Modulo left right) =
      (Synthesized $ foldBinaryInteger pos AST.Modulo mod (syn left) (syn right),
        AST.Modulo (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.And left right) =
      (Synthesized $ foldBinaryBoolean pos AST.And (&&) (syn left) (syn right),
       AST.And (Inherited inheritance) (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Not expr) =
      (Synthesized $ case foldedValue (syn expr)
                     of Just (AST.Boolean True) -> SynCFExp{foldedExp= (pos, Abstract.literal (pos, Abstract.false)),
                                                            foldedValue= Just Abstract.false}
                        Just (AST.Boolean False) -> SynCFExp{foldedExp= (pos, Abstract.literal (pos, Abstract.true)),
                                                             foldedValue= Just Abstract.true}
                        Nothing -> SynCFExp{foldedExp= (pos, AST.Not $ foldedExp $ syn expr),
                                            foldedValue= Nothing},
       AST.Not (Inherited inheritance))
--   attribution ConstantFold (pos, _) (Inherited inheritance, expression) =
--      (Synthesized SynCF{folded= (pos, (folded . syn) Rank2.<$> expression)}, const (Inherited inheritance) <$> expression)


instance Attribution ConstantFold (AST.Value l l)
                     (Int, AST.Value l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.Integer n) (Inherited inheritance, _) =
      (Synthesized SynCF{folded= (pos, AST.Integer n)}, AST.Integer n)

foldBinaryArithmetic :: forall l f. (f ~ ((,) Int),
                                     Abstract.Expression l ~ AST.Expression l, Abstract.Value l ~ AST.Value l,
                                     Abstract.Wirthy l, Abstract.CoWirthy l) =>
                        Int
                     -> (f (Abstract.Expression l l f f) -> f (Abstract.Expression l l f f) -> AST.Expression l l f f)
                     -> (forall n. Num n => n -> n -> n)
                     -> SynCFExp l -> SynCFExp l -> SynCFExp l
foldBinaryArithmetic pos node op l r = case join (foldValues <$> foldedValue l <*> foldedValue r)
                                       of Just v -> SynCFExp{foldedExp= (pos, AST.Literal (pos, v)),
                                                             foldedValue= Just v}
                                          Nothing -> SynCFExp{foldedExp= (pos, node (foldedExp l) (foldedExp r)),
                                                              foldedValue= Nothing}
   where foldValues :: AST.Value l l f f -> AST.Value l l f f -> Maybe (AST.Value l l f f)
         foldValues (AST.Integer l') (AST.Integer r') = Just (AST.Integer $ op l' r')
         foldValues (AST.Real l')    (AST.Real r')    = Just (AST.Real $ op l' r')
         foldValues (AST.Integer l') (AST.Real r')    = Just (AST.Real $ op (fromIntegral l') r')
         foldValues (AST.Real l')    (AST.Integer r') = Just (AST.Real $ op l' (fromIntegral r'))
         foldValues _ _ = Nothing

foldBinaryFractional :: forall l f. (f ~ ((,) Int),
                                     Abstract.Expression l ~ AST.Expression l, Abstract.Value l ~ AST.Value l,
                                     Abstract.Wirthy l, Abstract.CoWirthy l) =>
                        Int
                     -> (f (Abstract.Expression l l f f) -> f (Abstract.Expression l l f f) -> AST.Expression l l f f)
                     -> (forall n. Fractional n => n -> n -> n)
                     -> SynCFExp l -> SynCFExp l -> SynCFExp l
foldBinaryFractional pos node op l r = case join (foldValues <$> foldedValue l <*> foldedValue r)
                                       of Just v -> SynCFExp{foldedExp= (pos, AST.Literal (pos, v)),
                                                             foldedValue= Just v}
                                          Nothing -> SynCFExp{foldedExp= (pos, node (foldedExp l) (foldedExp r)),
                                                              foldedValue= Nothing}
   where foldValues :: AST.Value l l f f -> AST.Value l l f f -> Maybe (AST.Value l l f f)
         foldValues (AST.Real l')    (AST.Real r')    = Just (AST.Real $ op l' r')
         foldValues _ _ = Nothing

foldBinaryInteger :: forall l f. (f ~ ((,) Int),
                                  Abstract.Expression l ~ AST.Expression l, Abstract.Value l ~ AST.Value l,
                                  Abstract.Wirthy l, Abstract.CoWirthy l) =>
                        Int
                     -> (f (Abstract.Expression l l f f) -> f (Abstract.Expression l l f f) -> AST.Expression l l f f)
                     -> (forall n. Integral n => n -> n -> n)
                     -> SynCFExp l -> SynCFExp l -> SynCFExp l
foldBinaryInteger pos node op l r = case join (foldValues <$> foldedValue l <*> foldedValue r)
                                    of Just v -> SynCFExp{foldedExp= (pos, AST.Literal (pos, v)),
                                                          foldedValue= Just v}
                                       Nothing -> SynCFExp{foldedExp= (pos, node (foldedExp l) (foldedExp r)),
                                                           foldedValue= Nothing}
   where foldValues :: AST.Value l l f f -> AST.Value l l f f -> Maybe (AST.Value l l f f)
         foldValues (AST.Integer l') (AST.Integer r') = Just (AST.Integer $ op l' r')
         foldValues _ _ = Nothing

foldBinaryBoolean :: forall l f. (f ~ ((,) Int),
                                  Abstract.Expression l ~ AST.Expression l, Abstract.Value l ~ AST.Value l,
                                  Abstract.Wirthy l, Abstract.CoWirthy l) =>
                     Int
                  -> (f (Abstract.Expression l l f f) -> f (Abstract.Expression l l f f) -> AST.Expression l l f f)
                  -> (Bool -> Bool -> Bool)
                  -> SynCFExp l -> SynCFExp l -> SynCFExp l
foldBinaryBoolean pos node op l r = case join (foldValues <$> foldedValue l <*> foldedValue r)
                                    of Just v -> SynCFExp{foldedExp= (pos, AST.Literal (pos, v)),
                                                          foldedValue= Just v}
                                       Nothing -> SynCFExp{foldedExp= (pos, node (foldedExp l) (foldedExp r)),
                                                           foldedValue= Nothing}
   where foldValues :: AST.Value l l f f -> AST.Value l l f f -> Maybe (AST.Value l l f f)
         foldValues (AST.Boolean l') (AST.Boolean r') = Just (AST.Boolean $ op l' r')
         foldValues _ _ = Nothing

instance (Abstract.Wirthy l, Abstract.Nameable l, Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Attribution ConstantFold (AST.Element l l) (Int, AST.Element l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Element expr) =
      (Synthesized SynCF{folded= (pos, AST.Element (foldedExp $ syn expr))},
       AST.Element (Inherited inheritance))
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Range low high) =
      (Synthesized SynCF{folded= (pos, AST.Range (foldedExp $ syn low) (foldedExp $ syn high))},
       AST.Range (Inherited inheritance) (Inherited inheritance))

instance (Abstract.CoWirthy l, Abstract.Nameable l, Abstract.Oberon l, Ord (Abstract.QualIdent l),
          Abstract.Expression l l ((,) Int) ((,) Int) ~ AST.Expression l l ((,) Int) ((,) Int),
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l,
          Atts (Synthesized ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF (Abstract.Designator l l ((,) Int) ((,) Int), Maybe (Abstract.Expression l l ((,) Int) ((,) Int)))) =>
         Attribution ConstantFold (AST.Designator l l) (Int, AST.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   attribution ConstantFold (pos, AST.Variable q) (Inherited inheritance, _) =
      (Synthesized SynCF{folded= (pos, (AST.Variable q,
                                        Map.lookup q (env inheritance)))},
--                                        >>= Abstract.coExpression :: Maybe (AST.Expression l l ((,) Int) ((,) Int))))},
       AST.Variable q)
   attribution ConstantFold (pos, AST.Field _record fieldName) (Inherited inheritance, AST.Field record _fieldName) =
      (Synthesized SynCF{folded= (pos, (AST.Field (fmap fst $ folded $ syn record) fieldName, Nothing))},
       AST.Field (Inherited inheritance) fieldName)
   attribution ConstantFold (pos, AST.Index _array _indexes) (Inherited inheritance, AST.Index array indexes) =
      (Synthesized SynCF{folded= (pos, (AST.Index (fmap fst $ folded $ syn array) (foldedExp . syn <$> indexes), Nothing))},
       AST.Index (Inherited inheritance) (pure $ Inherited inheritance))
   attribution ConstantFold (pos, AST.TypeGuard _designator q) (Inherited inheritance, AST.TypeGuard designator _q) =
      (Synthesized SynCF{folded= (pos, (AST.TypeGuard (fmap fst $ folded $ syn designator) q, Nothing))},
       AST.TypeGuard (Inherited inheritance) q)
   attribution ConstantFold (pos, _) (Inherited inheritance, AST.Dereference pointer) =
      (Synthesized SynCF{folded= (pos, (AST.Dereference $ fmap fst $ folded $ syn pointer, Nothing))},
       AST.Dereference (Inherited inheritance))

-- * More boring Shallow.Functor instances, TH candidates
instance Ord (Abstract.QualIdent l) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (Modules l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Oberon l, Abstract.Nameable l, Ord (Abstract.QualIdent l), Show (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFMod' l (Abstract.Declaration l l),
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Module l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l, Ord (Abstract.QualIdent l), Abstract.Expression l ~ AST.Expression l,
          Rank2.Apply (Abstract.Block l l (Semantics ConstantFold)),
          Atts (Inherited ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.ProcedureHeading l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Block l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFMod' l (Abstract.Declaration l l),
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l),
          Atts (Synthesized ConstantFold) (Abstract.ProcedureHeading l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.ProcedureHeading l l),
          Atts (Synthesized ConstantFold) (Abstract.Block l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Block l l),
          Atts (Synthesized ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FormalParameters l l),
          Atts (Synthesized ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l)
         => Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                            (AST.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FormalParameters l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.ProcedureHeading l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Declaration l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFMod' l (Abstract.Declaration l l),
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Block l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.FPSection l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.FPSection l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FPSection l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
         (AST.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Wirthy l, Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.FPSection l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l, Abstract.Expression l ~ AST.Expression l) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (Deep.Product (AST.Expression l l) (AST.StatementSequence l l)
                                       (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Atts (Inherited ConstantFold) (Abstract.Statement l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Statement l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Statement l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Wirthy l, Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Deep.Product (Abstract.Expression l l) (Abstract.StatementSequence l l)
                                      (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Case l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.WithAlternative l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l),
          Atts (Synthesized ConstantFold) (Deep.Product (Abstract.Expression l l) (Abstract.StatementSequence l l)
                                        (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Deep.Product (Abstract.Expression l l) (Abstract.StatementSequence l l)),
          Atts (Synthesized ConstantFold) (Abstract.Case l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Case l l),
          Atts (Synthesized ConstantFold) (Abstract.WithAlternative l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.WithAlternative l l),
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l,
          Atts (Synthesized ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF (Abstract.Designator l l ((,) Int) ((,) Int), Maybe (Abstract.Expression l l ((,) Int) ((,) Int)))) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Statement l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Atts (Inherited ConstantFold) (Abstract.CaseLabels l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.CaseLabels l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.CaseLabels l l),
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Case l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l, Eq (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
         (AST.CaseLabels l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Atts (Inherited ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.StatementSequence l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.StatementSequence l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.WithAlternative l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.CoWirthy l, Abstract.Nameable l, Ord (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l, Abstract.Designator l ~ AST.Designator l, Abstract.Value l ~ AST.Value l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Element l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l,
          Atts (Synthesized ConstantFold) (Abstract.Element l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Element l l),
          Atts (Synthesized ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF (Abstract.Designator l l ((,) Int) ((,) Int), Maybe (Abstract.Expression l l ((,) Int) ((,) Int)))) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Wirthy l, Abstract.Nameable l, Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Element l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.CoWirthy l, Abstract.Nameable l, Abstract.Oberon l, Ord (Abstract.QualIdent l),
          Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Expression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l,
          Atts (Synthesized ConstantFold) (Abstract.Designator l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF (Abstract.Designator l l ((,) Int) ((,) Int), Maybe (Abstract.Expression l l ((,) Int) ((,) Int)))) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Designator l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Value l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l, Ord (Abstract.QualIdent l), Abstract.Expression l ~ AST.Expression l,
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.FieldList l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Inherited ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l),
          Atts (Synthesized ConstantFold) (Abstract.FieldList l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FieldList l l),
          Atts (Synthesized ConstantFold) (Abstract.FormalParameters l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.FormalParameters l l),
          Atts (Synthesized ConstantFold) (Abstract.ConstExpression l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCFExp l) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd
instance (Abstract.Nameable l,
          Atts (Inherited ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold)) ~ InhCF l,
          Atts (Synthesized ConstantFold) (Abstract.Type l l (Semantics ConstantFold) (Semantics ConstantFold))
          ~ SynCF' (Abstract.Type l l)) =>
         Shallow.Functor ConstantFold Placed (Semantics ConstantFold)
                         (AST.FieldList l l (Semantics ConstantFold) (Semantics ConstantFold)) where
   (<$>) = AG.mapDefault id snd

-- instance Full.Functor ConstantFold (AST.Declaration l l) Placed (Semantics ConstantFold) where
--    (<$>) = Full.defaultMapUp

-- * Unsafe Rank2 AST instances

instance Rank2.Apply (AST.Module l l f') where
   AST.Module name1 imports1 decls1 body1 <*> ~(AST.Module name2 imports2 decls2 body2) =
      AST.Module name1 imports1 (liftA2 Rank2.apply decls1 decls2) (liftA2 Rank2.apply body1 body2)

type Placed = ((,) Int)

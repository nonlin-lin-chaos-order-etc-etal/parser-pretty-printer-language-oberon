{-# Language FlexibleInstances #-}
module Main where

import Data.Either.Validation (Validation(..))
import Data.Functor.Identity (Identity(Identity))
import Data.List (isSuffixOf)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text, unpack)
import Data.Text.IO (readFile)
import Data.Text.Prettyprint.Doc (Pretty(pretty), layoutPretty, defaultLayoutOptions)
import Data.Text.Prettyprint.Doc.Render.Text (renderStrict)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath.Posix (combine)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, assertEqual, testCase)

import qualified Transformation.Rank2 as Rank2

import Language.Oberon (parseAndResolveModule, LanguageVersion(Oberon2), Options(..), Placed)
import Language.Oberon.AST (Language, Module)
import Language.Oberon.Pretty ()
import qualified Language.Oberon.Resolver as Resolver
import qualified Language.Oberon.TypeChecker as TypeChecker

import Prelude hiding (readFile)

main = exampleTree "" "examples" >>= defaultMain . testGroup "Oberon"

width = 80
contextLines = 3

exampleTree :: FilePath -> FilePath -> IO [TestTree]
exampleTree ancestry path =
   do let fullPath = combine ancestry path
      isDir <- doesDirectoryExist fullPath
      if isDir
         then (:[]) . testGroup path . concat <$> (listDirectory fullPath >>= mapM (exampleTree fullPath))
         else if ".Mod" `isSuffixOf` path
              then return . (:[]) . testCase path $
                   do moduleSource <- readFile fullPath
                      prettyModule <- prettyFile ancestry moduleSource
                      prettyModule' <- prettyFile ancestry prettyModule
                      assertEqual "pretty" prettyModule prettyModule'
              else return []

prettyFile :: FilePath -> Text -> IO Text
prettyFile dirPath source = do
   resolvedModule <- parseAndResolveModule Options{foldConstants= True,
                                                   checkTypes= True,
                                                   version= Oberon2}
                     dirPath source
   case resolvedModule
      of Failure (Left (Resolver.UnparseableModule err :| [])) -> assertFailure (unpack err)
         Failure errs -> assertFailure (show $ (onLastOfThree TypeChecker.errorMessage <$>) <$> errs)
         Success mod -> return (renderStrict $ layoutPretty defaultLayoutOptions $ pretty mod)

onLastOfThree f (a, b, c) = (a, b, f c)

instance Pretty (Module Language Language Placed Placed) where
   pretty m = pretty ((Identity . snd) Rank2.<$> m)

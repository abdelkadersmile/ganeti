{-| Generic data loader

This module holds the common code for parsing the input data after it
has been loaded from external sources.

-}

{-

Copyright (C) 2009 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Ganeti.HTools.Loader
    ( mergeData
    , checkData
    , assignIndices
    , lookupNode
    , lookupInstance
    , commonSuffix
    , RqType(..)
    , Request(..)
    ) where

import Data.Function (on)
import Data.List
import Data.Maybe (fromJust)
import Text.Printf (printf)

import qualified Ganeti.HTools.Container as Container
import qualified Ganeti.HTools.Instance as Instance
import qualified Ganeti.HTools.Node as Node

import Ganeti.HTools.Types

-- * Constants

-- | The exclusion tag prefix
exTagsPrefix :: String
exTagsPrefix = "htools:iextags:"

-- * Types

{-| The iallocator request type.

This type denotes what request we got from Ganeti and also holds
request-specific fields.

-}
data RqType
    = Allocate Instance.Instance Int -- ^ A new instance allocation
    | Relocate Idx Int [Ndx]         -- ^ Move an instance to a new
                                     -- secondary node
    | Evacuate [Ndx]                 -- ^ Evacuate nodes
    deriving (Show)

-- | A complete request, as received from Ganeti.
data Request = Request RqType Node.List Instance.List [String]
    deriving (Show)

-- * Functions

-- | Lookups a node into an assoc list.
lookupNode :: (Monad m) => [(String, Ndx)] -> String -> String -> m Ndx
lookupNode ktn inst node =
    case lookup node ktn of
      Nothing -> fail $ "Unknown node '" ++ node ++ "' for instance " ++ inst
      Just idx -> return idx

-- | Lookups an instance into an assoc list.
lookupInstance :: (Monad m) => [(String, Idx)] -> String -> m Idx
lookupInstance kti inst =
    case lookup inst kti of
      Nothing -> fail $ "Unknown instance '" ++ inst ++ "'"
      Just idx -> return idx

-- | Given a list of elements (and their names), assign indices to them.
assignIndices :: (Element a) =>
                 [(String, a)]
              -> (NameAssoc, [(Int, a)])
assignIndices =
    unzip . map (\ (idx, (k, v)) -> ((k, idx), (idx, setIdx v idx)))
          . zip [0..]

-- | Assoc element comparator
assocEqual :: (Eq a) => (a, b) -> (a, b) -> Bool
assocEqual = (==) `on` fst

-- | For each instance, add its index to its primary and secondary nodes.
fixNodes :: [(Ndx, Node.Node)]
         -> Instance.Instance
         -> [(Ndx, Node.Node)]
fixNodes accu inst =
    let
        pdx = Instance.pNode inst
        sdx = Instance.sNode inst
        pold = fromJust $ lookup pdx accu
        pnew = Node.setPri pold inst
        ac1 = deleteBy assocEqual (pdx, pold) accu
        ac2 = (pdx, pnew):ac1
    in
      if sdx /= Node.noSecondary
      then let sold = fromJust $ lookup sdx accu
               snew = Node.setSec sold inst
               ac3 = deleteBy assocEqual (sdx, sold) ac2
           in (sdx, snew):ac3
      else ac2

-- | Remove non-selected tags from the exclusion list
filterExTags :: [String] -> Instance.Instance -> Instance.Instance
filterExTags tl inst =
    let old_tags = Instance.tags inst
        new_tags = filter (\tag -> any (`isPrefixOf` tag) tl)
                   old_tags
    in inst { Instance.tags = new_tags }

-- | Update the movable attribute
updateMovable :: [String] -> Instance.Instance -> Instance.Instance
updateMovable exinst inst =
    if Instance.sNode inst == Node.noSecondary ||
       Instance.name inst `elem` exinst
    then Instance.setMovable inst False
    else inst

-- | Compute the longest common suffix of a list of strings that
-- | starts with a dot.
longestDomain :: [String] -> String
longestDomain [] = ""
longestDomain (x:xs) =
      foldr (\ suffix accu -> if all (isSuffixOf suffix) xs
                              then suffix
                              else accu)
      "" $ filter (isPrefixOf ".") (tails x)

-- | Extracts the exclusion tags from the cluster configuration
extractExTags :: [String] -> [String]
extractExTags =
    map (drop (length exTagsPrefix)) .
    filter (isPrefixOf exTagsPrefix)

-- | Extracts the common suffix from node/instance names
commonSuffix :: Node.List -> Instance.List -> String
commonSuffix nl il =
    let node_names = map Node.name $ Container.elems nl
        inst_names = map Instance.name $ Container.elems il
    in longestDomain (node_names ++ inst_names)

-- | Initializer function that loads the data from a node and instance
-- list and massages it into the correct format.
mergeData :: [(String, DynUtil)]  -- ^ Instance utilisation data
          -> [String]             -- ^ Exclusion tags
          -> [String]             -- ^ Untouchable instances
          -> (Node.AssocList, Instance.AssocList, [String])
          -- ^ Data from backends
          -> Result (Node.List, Instance.List, [String])
mergeData um extags exinsts (nl, il, tags) =
  let il2 = Container.fromAssocList il
      il3 = foldl' (\im (name, n_util) ->
                        case Container.findByName im name of
                          Nothing -> im -- skipping unknown instance
                          Just inst ->
                              let new_i = inst { Instance.util = n_util }
                              in Container.add (Instance.idx inst) new_i im
                   ) il2 um
      allextags = extags ++ extractExTags tags
      il4 = Container.map (filterExTags allextags .
                           updateMovable exinsts) il3
      nl2 = foldl' fixNodes nl (Container.elems il4)
      nl3 = Container.fromAssocList
            (map (\ (k, v) -> (k, Node.buildPeers v il4)) nl2)
      node_names = map (Node.name . snd) nl
      inst_names = map (Instance.name . snd) il
      common_suffix = longestDomain (node_names ++ inst_names)
      snl = Container.map (computeAlias common_suffix) nl3
      sil = Container.map (computeAlias common_suffix) il4
      all_inst_names = concatMap allNames $ Container.elems sil
  in if not $ all (`elem` all_inst_names) exinsts
     then Bad $ "Some of the excluded instances are unknown: " ++
          show (exinsts \\ all_inst_names)
     else Ok (snl, sil, tags)

-- | Checks the cluster data for consistency.
checkData :: Node.List -> Instance.List
          -> ([String], Node.List)
checkData nl il =
    Container.mapAccum
        (\ msgs node ->
             let nname = Node.name node
                 nilst = map (`Container.find` il) (Node.pList node)
                 dilst = filter (not . Instance.running) nilst
                 adj_mem = sum . map Instance.mem $ dilst
                 delta_mem = truncate (Node.tMem node)
                             - Node.nMem node
                             - Node.fMem node
                             - nodeImem node il
                             + adj_mem
                 delta_dsk = truncate (Node.tDsk node)
                             - Node.fDsk node
                             - nodeIdsk node il
                 newn = Node.setFmem (Node.setXmem node delta_mem)
                        (Node.fMem node - adj_mem)
                 umsg1 = [printf "node %s is missing %d MB ram \
                                 \and %d GB disk"
                                 nname delta_mem (delta_dsk `div` 1024) |
                                 delta_mem > 512 || delta_dsk > 1024]::[String]
             in (msgs ++ umsg1, newn)
        ) [] nl

-- | Compute the amount of memory used by primary instances on a node.
nodeImem :: Node.Node -> Instance.List -> Int
nodeImem node il =
    let rfind = flip Container.find il
    in sum . map (Instance.mem . rfind)
           $ Node.pList node

-- | Compute the amount of disk used by instances on a node (either primary
-- or secondary).
nodeIdsk :: Node.Node -> Instance.List -> Int
nodeIdsk node il =
    let rfind = flip Container.find il
    in sum . map (Instance.dsk . rfind)
           $ Node.pList node ++ Node.sList node

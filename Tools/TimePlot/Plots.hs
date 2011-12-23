{-# LANGUAGE ParallelListComp, ScopedTypeVariables, BangPatterns #-}
module Tools.TimePlot.Plots (
    initGen
) where

import Control.Monad
import qualified Control.Monad.Trans.State.Strict as St
import qualified Control.Monad.Trans.RWS.Strict as RWS
import Control.Arrow
import Data.List
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Set as Set
import qualified Data.ByteString.Char8 as S

import Data.Time

import Data.Accessor

import Graphics.Rendering.Chart
import Graphics.Rendering.Chart.Event

import Data.Colour
import Data.Colour.Names

import Data.Monoid

import Tools.TimePlot.Types
import Tools.TimePlot.Incremental

type PlotGen = String -> LocalTime -> LocalTime -> StreamSummary (LocalTime, InEvent) PlotData

initGen :: ChartKind LocalTime -> PlotGen
initGen (KindACount bs)         = genActivity (\sns n -> n) bs
initGen (KindAPercent bs b)     = genActivity (\sns n -> 100*n/b) bs
initGen (KindAFreq bs)          = genActivity (\sns n -> if n == 0 then 0 else (n / sum (M.elems sns))) bs
initGen (KindFreq bs k)         = genAtoms atoms2freqs bs k
  where  atoms2freqs as m = let n = length as in [fromIntegral (M.findWithDefault 0 a m)/fromIntegral n | a <- as]
initGen (KindHistogram bs k)    = genAtoms atoms2hist bs k
  where  atoms2hist as m = [fromIntegral (M.findWithDefault 0 a m) | a <- as]
initGen KindEvent               = genEventPlot
initGen (KindQuantile bs vs)    = genQuantile bs vs
initGen (KindBinFreq  bs vs)    = genBinFreqs bs vs
initGen (KindBinHist  bs vs)    = genBinHist  bs vs
initGen KindLines               = genLines
initGen (KindDots     alpha)    = genDots alpha
initGen (KindSum bs ss)         = genSum bs ss
initGen (KindCumSum ss)         = genCumSum ss
initGen (KindDuration sk)       = genDuration sk
initGen (KindWithin _ _)        = \name -> error $ "KindDuration should not be plotted: track " ++ show name
initGen KindNone                = \name -> error $ "KindNone should not be plotted: track " ++ show name
initGen KindUnspecified         = \name -> error $ "Kind not specified for track " ++ show name ++ " (have you misspelled -dk or any of -k arguments?)"

plotTrackBars :: [(LocalTime,[Double])] -> [String] -> String -> [Colour Double] -> PlotData
plotTrackBars values titles name colors = PlotBarsData {
        plotName = name,
        barsStyle = BarsStacked,
        barsValues = values,
        barsStyles = [(solidFillStyle c, Nothing) | (i,_) <- [0..]`zip`titles | c <- transparent:map opaque colors],
        barsTitles = titles
    }

plotLines :: String -> [(S.ByteString, [(LocalTime,Double)])] -> PlotData
plotLines name vss = PlotLinesData {
        plotName = name,
        linesData = [vs | (_, vs) <- vss],
        linesStyles = [solidLine 1 color | _ <- vss | color <- map opaque colors],
        linesTitles = [S.unpack subtrack | (subtrack, _) <- vss]
    }

genValues (t,InValue s v) = Just (t,s,v)
genValues _               = Nothing

genEdges (t,InEdge s e) = Just (t,s,e)
genEdges _              = Nothing

valuesDropTrack (t, InValue s v) = Just (t,v)
valuesDropTrack _                = Nothing

atomsDropTrack (t, InAtom s a) = Just (t,a)
atomsDropTrack _               = Nothing

genLines :: PlotGen
genLines name t0 t1 = genFilterMap genValues $ listSummary (data2plot . groupByTrack)
  where
    data2plot vss = PlotLinesData {
        plotName = name,
        linesData = [vs | (_,vs) <- vss],
        linesStyles = [solidLine 1 color | _ <- vss | color <- map opaque colors],
        linesTitles = [S.unpack subtrack | (subtrack, _) <- vss]
      }

genDots :: Double -> PlotGen
genDots alpha name t0 t1 = genFilterMap genValues $ listSummary (data2plot . groupByTrack)
  where
    data2plot vss = PlotDotsData {
        plotName = name,
        dotsData = [vs | (_,vs) <- vss],
        dotsTitles = [S.unpack subtrack | (subtrack, _) <- vss],
        dotsColors = if alpha == 1 then map opaque colors else map (`withOpacity` alpha) colors
      }

summaryByFixedTimeBins t0 binSize = summaryByTimeBins (iterate (add binSize) t0)

lag :: [a] -> [(a,a)]
lag xs = xs `zip` tail xs

genByBins :: ([Double] -> [Double] -> [Double]) -> NominalDiffTime -> [Double] -> PlotGen
genByBins f binSize vs name t0 t1 = genFilterMap valuesDropTrack $ 
    summaryByFixedTimeBins t0 binSize $
    mapInputSummary (\(t,xs) -> (t, 0:f vs xs)) $
    listSummary (\tfs -> plotTrackBars tfs (binTitles vs) name colors)
  where
    binTitles vs = [low]++[show v1++".."++show v2 | (v1,v2) <- lag vs]++[high]
      where
        low = "<"++show (head vs)
        high = ">"++show (last vs)

genBinHist :: NominalDiffTime -> [Double] -> PlotGen
genBinHist = genByBins values2binHist

genBinFreqs :: NominalDiffTime -> [Double] -> PlotGen
genBinFreqs = genByBins values2binFreqs

values2binFreqs :: (Ord a) => [a] -> [a] -> [Double]
values2binFreqs bins xs = map toFreq $ values2binHist bins xs
  where
    n = length xs
    toFreq = if n==0 then const 0 else (\k -> k/fromIntegral n)

values2binHist bins xs = values2binHist' bins $ sort xs
  where
    values2binHist' []     xs = [fromIntegral (length xs)]
    values2binHist' (a:as) xs = fromIntegral (length xs0) : values2binHist' as xs'
      where (xs0,xs') = span (<a) xs

genQuantile :: NominalDiffTime -> [Double] -> PlotGen
genQuantile binSize qs name t0 t1 = genFilterMap valuesDropTrack $
    summaryByFixedTimeBins t0 binSize $
    mapInputSummary (\(t,xs) -> (t,diffs (getQuantiles qs xs))) $
    listSummary (\tqs -> plotTrackBars tqs quantileTitles name colors)
  where
    quantileTitles = [""]++[show p1++".."++show p2++"%" | (p1,p2) <- lag percents ]
    percents = map (floor . (*100.0)) $ [0.0] ++ qs ++ [1.0]
    diffs xs = zipWith (-) xs (0:xs)

getQuantiles :: (Ord a) => [Double] -> [a] -> [a]
getQuantiles qs = \xs -> quantiles' (sort xs)
  where
    qs' = sort qs
    quantiles' [] = []
    quantiles' xs = index (0:ns++[n-1]) 0 xs
      where
        n  = length xs
        ns = map (floor . (*(fromIntegral n-1))) qs'

        index _         _ []     = []
        index []        _ _      = []
        index [i]       j (x:xs)
          | i<j  = []
          | i==j  = [x]
          | True = index [i] (j+1) xs
        index (i:i':is) j (x:xs)
          | i<j  = index (i':is)   j     (x:xs)
          | i>j  = index (i:i':is) (j+1) xs
          | i==i' = x:index (i':is) j     (x:xs)
          | True = x:index (i':is) (j+1) xs

genAtoms :: ([S.ByteString] -> M.Map S.ByteString Int -> [Double]) ->
           NominalDiffTime -> PlotBarsStyle -> PlotGen
genAtoms f binSize k name t0 t1 = genFilterMap atomsDropTrack $
    mapOutputSummary (uncurry h) (teeSummary uniqueAtoms fInBins)
  where 
    fInBins :: StreamSummary (LocalTime, S.ByteString) [(LocalTime, M.Map S.ByteString Int)]
    fInBins = summaryByFixedTimeBins t0 binSize $
              mapInputSummary (\(t,as) -> (t, counts as)) $
              listSummary id
    counts  = foldl' insert M.empty
      where
        insert m a = case M.lookup a m of
          Nothing -> M.insert a 1     m
          Just !n -> M.insert a (n+1) m

    uniqueAtoms :: StreamSummary (LocalTime,S.ByteString) [S.ByteString]
    uniqueAtoms = mapInputSummary (\(t,a) -> a) $ statefulSummary M.empty (\a -> M.insert a ()) M.keys

    h :: [S.ByteString] -> [(LocalTime, M.Map S.ByteString Int)] -> PlotData
    h as tfs = plotTrackBars (map (\(t,counts) -> (t,f as counts)) tfs) (map show as) name colors

uniqueSubtracks :: StreamSummary (LocalTime,S.ByteString,a) [S.ByteString]
uniqueSubtracks = mapInputSummary (\(t,s,a) -> s) $ statefulSummary M.empty (\a -> M.insert a ()) M.keys

genSum :: NominalDiffTime -> SumSubtrackStyle -> PlotGen
genSum binSize ss name t0 t1 = genFilterMap genValues $
    mapOutputSummary (uncurry h) (teeSummary uniqueSubtracks sumsInBins)
  where 
    sumsInBins :: StreamSummary (LocalTime,S.ByteString,Double) [(LocalTime, M.Map S.ByteString Double)]
    sumsInBins = mapInputSummary (\(t,s,v) -> (t,(s,v))) $
                 summaryByFixedTimeBins t0 binSize $
                 mapInputSummary (\(t,tvs) -> (t, fromListWith' (+) tvs)) $
                 listSummary id

    h :: [S.ByteString] -> [(LocalTime, M.Map S.ByteString Double)] -> PlotData
    h tracks binSums = plotLines name rows
      where
        rowsT' = case ss of
          SumOverlayed -> map (\(t,ss) -> (t, M.toList ss)) binSums
          SumStacked   -> map (\(t,ss) -> (t, stack ss))    binSums

        stack :: M.Map S.ByteString Double -> [(S.ByteString, Double)]
        stack ss = zip tracks (scanl1 (+) (map (\x -> M.findWithDefault 0 x ss) tracks))
        
        rows :: [(S.ByteString, [(LocalTime, Double)])]
        rows = M.toList $ fmap sort $ M.fromListWith (++) $
          [(track, [(t,sum)]) | (t, m) <- rowsT', (track, sum) <- m]

genCumSum :: SumSubtrackStyle -> PlotGen
genCumSum ss name t0 t1 = genFilterMap genValues $ listSummary (plotLines name . data2plot ss)
  where
    data2plot :: SumSubtrackStyle -> [(LocalTime, S.ByteString, Double)] -> [(S.ByteString, [(LocalTime, Double)])]
    data2plot SumOverlayed es = [(s, scanl (\(t1,s) (t2,v) -> (t2,s+v)) (t0, 0) vs) | (s, vs) <- groupByTrack es]
    data2plot SumStacked   es = rows
      where
        allTracks = Set.toList $ Set.fromList [track | (t, track, v) <- es]

        rows :: [(S.ByteString, [(LocalTime, Double)])]
        rows = groupByTrack [(t, track, v) | (t, tvs) <- rowsT, (track,v) <- tvs]

        rowsT :: [(LocalTime, [(S.ByteString, Double)])]
        rowsT = (t0, zip allTracks (repeat 0)) : St.evalState (mapM addDataPoint es) M.empty
        
        addDataPoint (t, track, v) = do
          St.modify (M.insertWith (+) track v)
          st <- St.get
          let trackSums = map (\x -> M.findWithDefault 0 x st) allTracks
          return (t, allTracks `zip` (scanl1 (+) trackSums))
 
genActivity :: (M.Map S.ByteString Double -> Double -> Double) -> NominalDiffTime -> PlotGen
genActivity f bs name t0 t1 = genFilterMap genEdges $
    mapOutputSummary (uncurry h) (teeSummary uniqueSubtracks binAreas)
  where 
    binAreas :: StreamSummary (LocalTime,S.ByteString,Edge) [(LocalTime, M.Map S.ByteString Double)]
    binAreas = mapOutputSummary (map (\((t1,t2),m) -> (t1,m))) $ edges2binsSummary bs t0 t1

    h tracks binAreas = (plotTrackBars barsData ("":map S.unpack tracks) name colors) { barsStyle = BarsStacked }
      where
        barsData = [(t, 0:map (f m . flip (M.findWithDefault 0) m) tracks) | (t,m) <- binAreas]

ws2summary :: (Monoid w) => (a -> RWS.RWS () w s ()) -> RWS.RWS () w s () -> s -> StreamSummary a w
ws2summary step flush s0 = statefulSummary init insert finalize
  where
    init = (s0, mempty)
    insert a (s, w) = let (!s',!w') = RWS.execRWS (step a) () s in (s', w `mappend` w')
    finalize (s, w) = w

st2summary :: (a -> St.State s ()) -> St.State s b -> s -> StreamSummary a b
st2summary step flush s0 = statefulSummary s0 (St.execState . step) (St.evalState flush)

edges2binsSummary :: (Ord t,HasDelta t,Show t) => Delta t -> t -> t -> StreamSummary (t,S.ByteString,Edge) [((t,t), M.Map S.ByteString Double)]
edges2binsSummary binSize tMin tMax = ws2summary step flush (M.empty, iterate (add binSize) tMin)
  where
    getBin       = RWS.gets $ \(m, t1:t2:ts) -> (t1, t2)
    nextBin      = RWS.get >>= \(m, t1:t2:ts) -> RWS.put (m, t2:ts)
    getState s t = RWS.gets $ \(m, _) -> (M.findWithDefault (0,t,0,0) s m)
    putState s v = RWS.get >>= \(m, ts) -> RWS.put (M.insert s v m, ts)
    modState s t f = getState s t >>= putState s . f
    getStates    = RWS.gets (\(m,_) -> M.toList m)

    flushBin = do
      bin@(t1,t2) <- getBin
      states <- getStates
      let binSizeSec = toSeconds (t2 `sub` t1) t1
      RWS.tell [(bin, M.fromList [(s, (fromIntegral npulse + area + toSeconds (t2 `sub` start) t2*nopen)/binSizeSec) 
                                 |(s,(area,start,nopen,npulse)) <- states])]
      forM_ states $ \(s, (area,start,nopen,_)) -> putState s (0,t2,nopen,0)
      nextBin

    step ev@(t, s, e) = do
      (t1, t2) <- getBin
      if t < t1
        then error "Times are not in ascending order"
        else if (t >= t2)
               then flushBin >> step ev
               else step'' ev
    step'' ev@(t,s,e) = do (t1,t2) <- getBin; when (t < t1 || t >= t2) (error "Outside bin"); step' ev
    step' (t, s, SetTo _) = modState s t id
    step' (t, s, Pulse _) = modState s t $ \(area, start, nopen, npulse) -> (area,                                   t, nopen,   npulse+1)
    step' (t, s, Rise)    = modState s t $ \(area, start, nopen, npulse) -> (area+toSeconds (t `sub` start) t*nopen, t, nopen+1, npulse)
    step' (t, s, Fall)    = modState s t $ \(area, start, nopen, npulse) -> (area+toSeconds (t `sub` start) t*nopen, t, nopen-1, npulse)
    flush                 = getBin >>= \(t1,t2) -> when (t2 <= tMax) (flushBin >> flush)

edges2eventsSummary' :: forall t a . (Ord t) => t -> t -> StreamSummary (S.ByteString, Event t Status) a -> StreamSummary (t,S.ByteString,Edge) a
edges2eventsSummary' t0 t1 s = st2summary step flush (M.empty, s)
  where
    getTrackStates   = St.gets fst
    putTrackStates t = St.gets snd >>= \s -> St.put (t,s)
    getSummary       = St.gets snd
    putSummary  s    = St.gets fst >>= \ts -> St.put (ts,s)
    tellSummary e    = getSummary >>= \s -> putSummary (genInsert s e)

    getTrack  s   = getTrackStates >>= return . M.findWithDefault (t0, 0, emptyStatus) s
    putTrack  s t = getTrackStates >>= putTrackStates . M.insert s t
    killTrack s   = getTrackStates >>= putTrackStates . M.delete s
    trackCase s whenZero withNonzero = do
      (t0, numActive, st) <- getTrack s
      case numActive of
        0 -> whenZero
        n -> withNonzero t0 numActive st

    emptyStatus = Status "" ""

    step (t,s,Pulse st) = tellSummary (s, PulseEvent t st)
    step (t,s,SetTo st) = trackCase s (putTrack s (t, 1, st))
                                      (\t0 n st0 -> tellSummary (s, LongEvent (t0,True) (t,True) st0) >> 
                                                    putTrack s (t, n, st))
    step (t,s,Rise)     = trackCase s (putTrack s (t, 1, emptyStatus)) 
                                      (\t0 n st -> putTrack s (t, n+1, st))
    step (t,s,Fall)     = do
      (t0, numActive, st) <- getTrack s
      case numActive of
        1 -> tellSummary (s, LongEvent (t0,True) (t,True) st) >> killTrack s
        n -> putTrack s (t0, max 0 (n-1), st)

    flush = do
      trackStates <- fmap M.toList getTrackStates
      mapM_ (\(s, (t0,_,st)) -> tellSummary (s, LongEvent (t0,True) (t1,False) st)) trackStates
      fmap genResult getSummary

edges2eventsSummary :: (Ord t) => t -> t -> StreamSummary (t,S.ByteString,Edge) [(S.ByteString,Event t Status)]
edges2eventsSummary t0 t1 = edges2eventsSummary' t0 t1 (listSummary id)

edges2durationsSummary :: forall t a . (Ord t, HasDelta t) => t -> t -> String -> StreamSummary (t,InEvent) a -> StreamSummary (t,S.ByteString,Edge) a
edges2durationsSummary t0 t1 commonTrack = edges2eventsSummary' t0 t1 . genFilterMap genDurations
  where
    genDurations (track, LongEvent (t1,True) (t2,True) _) = Just (t2, InValue commonTrackBS $ toSeconds (t2 `sub` t1) (undefined :: t))
    genDurations _                                        = Nothing
    commonTrackBS = S.pack commonTrack

genEventPlot :: PlotGen
genEventPlot name t0 t1 = genFilterMap genEdges $ 
                          mapOutputSummary (\evs -> PlotEventData { plotName = name, eventData = map snd evs }) $ 
                          edges2eventsSummary t0 t1
-- TODO Multiple tracks

genDuration :: ChartKind LocalTime -> PlotGen
genDuration sk name t0 t1 = genFilterMap genEdges $ edges2durationsSummary t0 t1 name (initGen sk name t0 t1)

-- UTILITIES

fromListWith' :: (Ord k) => (a -> a -> a) -> [(k,a)] -> M.Map k a
fromListWith' f kvs = foldl' insert M.empty kvs
  where
    insert m (k,v) = case M.lookup k m of
      Nothing  -> M.insert k v        m
      Just !v' -> M.insert k (f v' v) m

colors = cycle [green,blue,red,brown,yellow,orange,grey,purple,violet,lightblue]

groupByTrack xs = M.toList $ sort `fmap` M.fromListWith (++) [(s, [(t,v)]) | (t,s,v) <- xs]


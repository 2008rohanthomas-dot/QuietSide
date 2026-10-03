# Quietside iOS App

A native SwiftUI walking-navigation app for comparing lower-stimulation routes around UIUC and Champaign-Urbana.

## Open and run

1. Open `Quietside.xcodeproj` in Xcode.
2. Select a connected iPhone for the most reliable location test, or an iPhone simulator.
3. Press Run.
4. Tap **Use location** when you are ready to search.

For simulator testing, choose **Debug → Simulate Location → UIUC** (from the included `UIUC.gpx`) or another GPX walking route in Xcode before starting navigation. The simulator does not provide coordinates merely because location permission was granted. You can also use **Choose start** in the app. The project was created with Xcode 27 and builds successfully for the generic iOS Simulator target.

## Implemented

- Real foreground location using Core Location, including permission, poor-accuracy, stale-fix, and unavailable states
- Ten-second location timeout with retry, Settings recovery, and a searchable manual-start fallback
- Map camera centered on the actual user rather than a hard-coded UIUC coordinate
- Real destination search through `MKLocalSearch`
- Real walking geometry, steps, distance, and ETA through `MKDirections`
- Honest handling when Apple Maps returns no alternate route
- GPS-driven map matching and route progress
- Automatic maneuver advancement, remaining distance/time, arrival detection, and sustained off-route rerouting
- Official City of Champaign ArcGIS streetlight and traffic-signal queries around each real route
- Source, method, coverage, and confidence shown for every sensory dimension
- Missing public live noise/crowd data shown as **Unknown**, not converted into a favorable score
- Campustown environmental-exposure field built on-device from bundled IDOT AADT roadway data and OpenStreetMap venues, drawn as smooth contour bands on every map
- Curated major signalized intersections and activity hotspots shown as subtle map markers, with a compact legend and layer toggles
- Exposure-aware route alternatives: Apple Maps is asked for walks through the calmest nearby blocks, then every route is scored against the same field the map draws
- Five-second on-device dBFS measurement with optional local-only storage
- Persisted sensory preferences and source links in Settings
- Permission strings for location and microphone

## Architecture

- `LocationService.swift`: permission and filtered location updates
- `PlaceSearchService.swift`: Apple Maps place search
- `RouteService.swift`: walking alternatives and candidate selection
- `OfficialDataRepository.swift`: official-source registry and Champaign ArcGIS ingestion
- `PolylineGeometry.swift`: route projection and distance calculations
- `NavigationSession.swift`: live progress, maneuver selection, arrival, and rerouting
- `Models.swift`: provenance-aware route and sensory models; `WalkingRoute` wraps single or via-point Apple routes
- `EnvironmentalData.swift`: GeoJSON loading, curated stimuli, and the single weighting configuration (`EnvironmentalWeights`)
- `EnvironmentalExposureModel.swift`: exposure rasters, route sampling, calm via-point selection, and contour tracing
- `EnvironmentalMapLayer.swift`: cached store, map overlay content, legend, layer menu, and per-route exposure strip
- `Data/`: bundled `idot_aadt_campustown.geojson` and `campustown_places.geojson`

`SampleData.swift` now contains debug preview fixtures only. Production views do not use fixture locations, routes, places, or sensory scores.

## Data interpretation

Environmental exposure is a relative model, not a decibel measurement. Each road's AADT is log-scaled to a 0–1 intensity and spread with a Gaussian falloff that widens for busier roads (max over roads). Venues add a secondary, category-weighted activity influence (bars > restaurants/fast food > cafés/convenience > libraries). The combined raster (12 m cells) is contoured for the map and sampled every 8 m along each route for scoring, so the map and the route choice always use the same numbers. Routes mostly outside the modelled Campustown area are marked unknown rather than scored as calm.

City streetlight points describe infrastructure coverage only; they do not measure brightness, glare, flicker, or working condition. Traffic-signal density is shown as a derived crossing-complexity proxy, not live traffic volume. UIUC course schedules and the federal transportation-noise map are linked as official sources, but Quietside does not turn them into live crowd or sidewalk-noise claims.

Sound measurements are relative microphone power readings in dBFS, not calibrated dBA sound-pressure measurements. They remain on the device and are not yet incorporated into route scoring.

## Current boundaries

- Foreground navigation only
- Apple Maps controls which walking alternatives are returned
- Champaign-owned infrastructure coverage does not include every UIUC- or Urbana-owned asset
- No public official live pedestrian-density or sidewalk-level noise feed was available for this implementation
- A physical-device walking test is still required before presenting reroute thresholds as field-validated

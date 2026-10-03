# Quietside iOS App

A SwiftUI walking-navigation app for lower-stimulation routes around UIUC Campustown, built as a hackathon demo for Saturday, October 3, 2026 (Illinois Homecoming).

## Open and run

1. Open `Quietside.xcodeproj` in Xcode 27.
2. Choose an iPhone simulator or device and press Run.
3. Pick your sensory triggers, then search for a destination.

No location or microphone permission is requested. The demo origin is fixed to the Campus Instructional Facility (CIF), 1405 W Springfield Ave, Urbana.

## Demo flow

CIF → search a destination → compare **Fastest** and **Calmest** → switch the map between Overall / Noise / Crowd / Traffic → start the route (a simulated walk from CIF at 8× speed).

The clock button on the Explore map follows real Central Time by default. Its menu can jump to a moment in each of today's events so their effect on the map and routes can be shown at any time of day.

## How routing works

- **Destinations** come from `MKLocalSearch` around CIF. Nothing is pre-listed.
- **Candidates**: Apple Maps walking routes from CIF, plus routes forced through calm via points. The via points come from a least-cost (Dijkstra) corridor over the environmental cost grid and from the calmest minor-street points on either side of the direct line.
- **Fastest** is the candidate with the least travel time.
- **Calmest** is the candidate with the lowest sensory cost, among those within the detour limit:

  `cost = Σ segment time × (1 + noise + crowd + traffic + lights + visual + event penalties)`

  Each penalty is weighted by the user's triggers: selected triggers ×2.0, unselected ×0.25. Active events weigh ×2.0 when Noise or Crowds is selected. When no candidate beats the fastest route, Calmest is the fastest route and the app says so.

All weights live in `EnvironmentalWeights` (`EnvironmentalData.swift`).

## One environmental dataset

`EnvironmentalExposureModel` builds one 12 m grid per channel from the bundled data:

| Channel | Source |
| --- | --- |
| traffic | IDOT AADT roadway volumes (`Data/idot_aadt_campustown.geojson`) |
| crowd | Campustown venues (`Data/campustown_places.geojson`) + seeded pedestrian hubs (`CrowdHub`) |
| visual | Seeded storefront/nightlife hotspots + venue density |
| trafficSignalExposure | Seeded signalized intersections (`CampustownStimuli`) |
| noiseDb | Derived from traffic, crowd and event noise |

`EnvironmentSnapshot` applies the active events (`CampusEvents.swift`) for a given time. The heatmap contours, route exposure colors, route metrics, live navigation readouts and route costs all read the same snapshot grids.

## Events (Central Time, Oct 3 2026)

| Event | Time | Area |
| --- | --- | --- |
| Grange Grove Tailgating | 11:00 AM–3:15 PM | Grange Grove / stadium west side |
| Illinois Homecoming Football vs. Purdue | 3:15–6:45 PM | Gies Memorial Stadium |
| Homecoming Saturday Night LIVE | 6:00–9:00 PM | Downtown Champaign |

Status (Upcoming → Live → Ended) is derived from the clock. While an event is live, its area gets higher crowd, noise, traffic and visual values. Those raise route costs nearby, so Calmest can steer around it.

## Files

- `Models.swift`: profile, CIF origin, `WalkingRoute`, `RouteCandidate`
- `EnvironmentalData.swift`: triggers, weights, data loading, seeded stimuli and hubs
- `EnvironmentalExposureModel.swift`: grids, event snapshot, route pricing, corridor search, contours
- `CampusEvents.swift`: event schedule and status
- `EnvironmentStore.swift`: shared snapshot, clock, heatmap overlays
- `RouteService.swift`: candidate generation and Fastest/Calmest selection
- `PlaceSearchService.swift`: destination search
- `NavigationSession.swift`: simulated turn-by-turn along the chosen route
- `HomeView`, `RouteComparisonView`, `ActiveNavigationView`, `EnvironmentalMapLayer`, `OnboardingView`, `SettingsView`: UI

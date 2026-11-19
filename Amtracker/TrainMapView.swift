import SwiftUI
import MapKit

private struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct TrainMarker: View {
    let heading: Double?
    var body: some View {
        ZStack {
            if let heading {
                ZStack {
                    ArrowShape().fill(Theme.blue).overlay(ArrowShape().stroke(.white, lineWidth: 1.5))
                        .frame(width: 14, height: 12).offset(y: -24)
                }
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(heading))
            }
            Circle().fill(Theme.blue).frame(width: 30, height: 30)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
            Image(systemName: "tram.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
    }
}

/// Interactive map: bundled route (traveled solid, remainder lighter), train and target-station annotations.
struct TrainMapView: View {
    @ObservedObject var store: TrainStore
    @State private var position: MapCameraPosition = .automatic
    @State private var didInitialFrame = false

    private static let spanMeters = RouteGeometry.spanMiles * 1609.34

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $position, interactionModes: .all) {
                ForEach(Array(store.route.other.enumerated()), id: \.offset) { _, p in
                    MapPolyline(coordinates: p).stroke(Theme.route.opacity(0.4), lineWidth: 3)
                }
                if store.route.remaining.count > 1 {
                    MapPolyline(coordinates: store.route.remaining).stroke(Theme.route.opacity(0.4), lineWidth: 3)
                }
                if store.route.traveled.count > 1 {
                    MapPolyline(coordinates: store.route.traveled).stroke(Theme.route, lineWidth: 4.5)
                }
                ForEach(store.route.stops.filter { $0.code != store.display?.stationCode }, id: \.code) { s in
                    Annotation("", coordinate: s.coord, anchor: .center) {
                        Circle().fill(Theme.background).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Theme.route, lineWidth: 1.5))
                    }
                }
                if let d = store.display, let c = RouteGeometry.stationCoord(code: d.stationCode) {
                    Annotation(d.stationCode, coordinate: c, anchor: .center) {
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Theme.navy, lineWidth: 3.5))
                    }
                }
                if let c = store.trainCoordinate {
                    Annotation("", coordinate: c, anchor: .center) {
                        TrainMarker(heading: RouteGeometry.headingDegrees(store.display?.heading))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapScaleView(); MapCompass() }

            Button { recenter() } label: {
                Image(systemName: "location.fill").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .disabled(store.trainCoordinate == nil)
            .padding(12)
            .accessibilityLabel("Recenter on train")
        }
        .onChange(of: store.loadCount) { _, _ in
            // Follow the train only if the user hasn't moved the map since the last recenter.
            if !didInitialFrame || !position.positionedByUser { recenter() }
        }
        .onAppear { if store.trainCoordinate != nil, !didInitialFrame { recenter() } }
    }

    /// Frames ~70 miles across, centre biased slightly ahead of the train.
    private func recenter() {
        guard let train = store.trainCoordinate else { return }
        var center = train
        if let h = RouteGeometry.headingDegrees(store.display?.heading) {
            let off = Self.spanMeters * 0.14
            center.latitude += (off * cos(h * .pi / 180)) / 111_320
            center.longitude += (off * sin(h * .pi / 180)) / (111_320 * cos(train.latitude * .pi / 180))
        }
        didInitialFrame = true
        position = .region(MKCoordinateRegion(center: center, latitudinalMeters: Self.spanMeters, longitudinalMeters: Self.spanMeters))
    }
}

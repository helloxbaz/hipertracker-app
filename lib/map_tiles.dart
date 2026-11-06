import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// The same Google map tiles as the HiperTracker map in the ERP (road map, or satellite with labels).
TileLayer hsTiles({bool satellite = false}) => TileLayer(
      key: ValueKey(satellite ? 'satellite' : 'map'),
      urlTemplate: 'https://mt{s}.google.com/vt/lyrs=${satellite ? 'y' : 'm'}&hl=en&x={x}&y={y}&z={z}',
      subdomains: const ['0', '1', '2', '3'],
      maxNativeZoom: 20,
      userAgentPackageName: 'org.traccar.client',
    );

const hsAttribution = RichAttributionWidget(attributions: [TextSourceAttribution('Map data © Google')]);

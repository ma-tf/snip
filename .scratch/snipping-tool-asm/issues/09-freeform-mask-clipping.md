# Free-form mask and clipping

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: 06

## Question

How does a hand-traced free-form path become a clipped bitmap?

Decide the algorithm: `CreatePolygonRgn` + `SelectClipRgn` + `BitBlt` for a GDI-managed mask, versus building a per-pixel coverage mask by hand; how the traced points are collected and simplified during the drag; how the cut edge is antialiased, if at all; and what the selection's bounding box and resulting DIB turn out to be.

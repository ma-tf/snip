# Snip representation and clipboard formats

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: 02

## Question

What *is* a snip, in memory, and what gets published to the clipboard?

Decide the pixel representation (32bpp top-down `CreateDIBSection` DIB vs something else); the stride, alpha, and premultiplication rules; how the pristine post-capture image is retained so the Eraser can restore from it; how the bitmap flows capture → editor → clipboard → encoder without needless copies; and which clipboard format(s) to publish (`CF_DIB`, `CF_DIBV5`, `CF_BITMAP`, or a PNG stream in a registered `CF_PNG`).

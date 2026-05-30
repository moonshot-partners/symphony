import type { Evidence } from "./contract";

export type AcGroup = { ac: string; items: Evidence[] };

/**
 * Group evidence by acceptance criterion, preserving first-seen AC order.
 * Reuses the AC structure the Gate D `## AC Evidence` block already produces.
 * Pure: same input -> same output.
 */
export function groupEvidenceByAc(evidence: Evidence[]): AcGroup[] {
  const order: string[] = [];
  const byAc = new Map<string, Evidence[]>();
  for (const e of evidence) {
    const items = byAc.get(e.ac);
    if (items) {
      items.push(e);
    } else {
      byAc.set(e.ac, [e]);
      order.push(e.ac);
    }
  }
  return order.map((ac) => ({ ac, items: byAc.get(ac)! }));
}

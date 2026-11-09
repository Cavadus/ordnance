// Where the yellow line sits while a mod already in the profile is dragged
// to a new place in the same list. No runtime imports, so tests/unit can
// run this with plain Node.
//
// The landing slot matches the splice the mods page uses: the dragged row
// is removed first, then inserted at the target index. Dragging downward
// therefore lands after the row under the pointer. Dragging upward lands
// before it.

export type ReorderLineSide = "above" | "below";

/** `index` is local to the list being dragged (a category, or the whole
 * profile when there are no categories). */
export function reorderLineSide(index: number, from: number, to: number): ReorderLineSide | null {
    if (to === from) return null;
    if (to > from && index === to) return "below";
    if (to < from && index === to) return "above";
    return null;
}

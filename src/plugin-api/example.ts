// Compile with `tsc --target ES2020 --module none sdk/example.ts sdk/mtv.d.ts`.
// Output replaces the developer's plugin.js, not the app's SwiftUI pages.
// Add folders + resolve + continuation to use the optional native next-part action (MTV 59+).
const plugin: MTVPlugin = {
  handle(action, input) {
    if (action === "continuation") {
      if (input.collection !== "hello-parts" || !["part-1", "part-2"].includes(input.reference)) throw new Error("Unknown collection or current item");
      return {currentReference: input.reference, collectionReference: input.collection, label: "Next Episode",
        next: input.reference === "part-1" ? {id: "part-2", reference: "part-2", title: "Episode 2", subtitle: "P2", overview: "Implement resolve to provide playback.", source: "example"} : null};
    }
    if (action !== "browse") throw new Error("Unsupported action");
    if (input.folder === "hello-parts") return {items: [1, 2].map(number => ({
      id: "part-" + number, reference: "part-" + number, title: "Episode " + number,
      subtitle: "P" + number, overview: "Resolve a stable reference to a playback description.", source: "example"
    }))};
    return { items: [{ id: "hello", title: "Hello, MacTV", subtitle: "TypeScript Plugin",
      overview: "MacTV renders the native page.", source: "example", collectionReference: "hello-parts" }] };
  }
};

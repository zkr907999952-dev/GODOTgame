import { NodeIO } from "@gltf-transform/core";
import { ALL_EXTENSIONS } from "@gltf-transform/extensions";
import { dedup } from "@gltf-transform/functions";
import { MeshoptDecoder } from "meshoptimizer";
import fs from "fs";

await MeshoptDecoder.ready;

const ioIn = new NodeIO()
  .registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({ "meshopt.decoder": MeshoptDecoder });

const src = "/workspace/rouchangmoniqi3/public/models/city.glb";
const dst = "/workspace/rouchang-godot/assets/maps/city.glb";

console.log("reading...");
const doc = await ioIn.read(src);
console.log("meshes", doc.getRoot().listMeshes().length, "nodes", doc.getRoot().listNodes().length);

// Remove meshopt / quantization extensions from the document so write emits plain buffers.
for (const ext of [...doc.getRoot().listExtensionsUsed()]) {
  const name = ext.extensionName;
  if (name === "EXT_meshopt_compression" || name === "KHR_mesh_quantization") {
    console.log("removing extension", name);
    ext.dispose();
  }
}

await doc.transform(dedup());

const ioOut = new NodeIO().registerExtensions(ALL_EXTENSIONS);
await ioOut.write(dst, doc);
console.log("OK", dst, fs.statSync(dst).size);

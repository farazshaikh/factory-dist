document.getElementById("copy-command").addEventListener("click", async () => {
  const status = document.getElementById("copy-status");
  try {
    await navigator.clipboard.writeText(document.getElementById("install-command").textContent);
    status.textContent = "Install command copied.";
  } catch {
    status.textContent = "Clipboard unavailable. Select and copy the command above.";
  }
});

async function loadRelease() {
  const status = document.getElementById("release-status");
  const panel = document.getElementById("release-downloads");
  const platforms = ["aarch64-apple-darwin", "x86_64-apple-darwin", "x86_64-unknown-linux-gnu"];
  const urls = [];
  try {
    const read = async (relative) => {
      const response = await fetch(relative, { cache: "no-store", signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error("Release unavailable");
      const text = await response.text();
      if (text.length > 65536) throw new Error("Release metadata too large");
      return JSON.parse(text);
    };
    const timestamp = await read("updates/metadata/timestamp.json");
    const expires = Date.parse(timestamp.signed?.expires);
    if (!Number.isFinite(expires) || expires <= Date.now()) throw new Error("Release metadata expired");
    const manifests = await Promise.all(platforms.map(target => read(`updates/targets/stable-${target}.json`)));
    for (const [index, manifest] of manifests.entries()) {
      const target = platforms[index];
      if (manifest.target !== target || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(manifest.version)
        || !/^[a-f0-9]{40}$/.test(manifest.source_commit)
        || manifest.archive !== `factory-${manifest.version}-${target}.tar.gz`
        || !Number.isSafeInteger(manifest.storage_min) || manifest.storage_min < 1
        || !Number.isSafeInteger(manifest.storage_max) || manifest.storage_max < manifest.storage_min
        || manifest.version !== manifests[0].version || manifest.source_commit !== manifests[0].source_commit) {
        throw new Error("Release identity mismatch");
      }
    }
    for (const manifest of manifests) {
      const archive = document.querySelector(`[data-archive="${manifest.target}"]`);
      archive.href = `updates/targets/${manifest.archive}`;
      archive.download = manifest.archive;
      const descriptor = document.querySelector(`[data-descriptor="${manifest.target}"]`);
      const url = URL.createObjectURL(new Blob([JSON.stringify({ manifest, path: manifest.archive }, null, 2)], { type: "application/json" }));
      urls.push(url);
      descriptor.href = url;
      descriptor.download = `${manifest.archive}.json`;
    }
    const selection = document.getElementById("install-platform");
    const updateCommand = () => {
      const manifest = manifests.find(item => item.target === selection.value);
      if (!manifest) return;
      document.getElementById("manual-install-command").textContent = `tar -xzf '${manifest.archive}'\n./factory-${manifest.target}/bin/factory update install \\\n  --package '${manifest.archive}' \\\n  --manifest '${manifest.archive}.json'`;
    };
    selection.addEventListener("change", updateCommand);
    updateCommand();
    document.getElementById("copy-command").disabled = false;
    status.textContent = `Factory ${manifests[0].version} / Stable`;
    status.classList.add("available");
    panel.hidden = false;
  } catch {
    for (const url of urls) URL.revokeObjectURL(url);
    status.textContent = "Release downloads unavailable. Please retry later.";
    panel.hidden = true;
  }
}

loadRelease();
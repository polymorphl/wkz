Gaps DX majeurs


1. Pas de scaffolding

Nouveau projet = copier-coller build.zig + build.zig.zon + structure à la main depuis les exemples.

Fix: zig build scaffold -- --name mon-app ou un template GitHub.

---
2. Erreurs Zig invisibles côté JS

Si un handler Zig retourne error.SomethingFailed, le JS reçoit quoi ? Si la promise reste pending indéfiniment (comme mentionné dans le code bridge-js), c'est un trou noir de debugging.

Fix: Convention { ok: bool, error?: string } + timeout configurable sur invoke().

---


3. bridge-js non publié sur npm (local-only)
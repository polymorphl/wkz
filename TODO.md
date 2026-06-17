Gaps DX majeurs

1. Deux terminaux pour démarrer

Dev nécessite zig build run -Ddev=true + cd frontend && npm run dev séparément. Pas de commande unique. Wry/Tauri ont tauri dev qui orchestre les deux.

Fix: zig build dev qui spawne le frontend en subprocess.

---
2. Zéro type safety sur le bridge

invoke<T>("mon.handler", {...}) — le "mon.handler" est une string magique, T est manuel. Aucun autocomplete, aucune erreur si le nom change côté Zig.

Fix: Codegen — scanner les registerHandler(...) dans bridge.zig pour émettre un .d.ts avec tous les méthodes + types de retour. invoke devient invoke<Methods["shell.open"]>(...).

---
3. Pas de scaffolding

Nouveau projet = copier-coller build.zig + build.zig.zon + structure à la main depuis les exemples.

Fix: zig build scaffold -- --name mon-app ou un template GitHub.

---
4. Erreurs Zig invisibles côté JS

Si un handler Zig retourne error.SomethingFailed, le JS reçoit quoi ? Si la promise reste pending indéfiniment (comme mentionné dans le code bridge-js), c'est un trou noir de debugging.

Fix: Convention { ok: bool, error?: string } + timeout configurable sur invoke().

---
5. Pas de watch mode Zig

Frontend a HMR. Zig change → rebuild manuel + restart. Cassant en dev actif.

Fix: zig build watch via watchman/fsevents ou wrapper shell.

---
Moins urgent

- bridge-js non publié sur npm (local-only)
- Pas de docs générées automatiquement sur push (CI génère zig-out/docs/ mais pas hébergé)
- Pas de shortcut clavier documenté pour ouvrir WebKit inspector
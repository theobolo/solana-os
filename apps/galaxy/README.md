# Galaxy Live

Le validateur Galaxy en direct sur le badge, signé @ghosty.

**À l'écran :**

- le stake actif ;
- le rang par stake et la part du réseau ;
- la commission ;
- la progression de l'epoch ;
- les blocs produits et le taux de skip de l'epoch ;
- le compte à rebours jusqu'à la prochaine fenêtre leader ;
- le dernier bloc produit (nombre de transactions et frais).

**Les LED :**

- **Barre du haut (6 LED)** : pendant que Galaxy est leader, elle se remplit slot par slot. Une fenêtre fait 4 slots, soit environ 0,8 s en Alpenglow. Elle passe en dégradé du violet au vert Solana, et en rouge si un slot est skippé. À la fin de la fenêtre, elle fait un flash puis s'éteint en fondu.
- **Deux LED latérales** : elles respirent de plus en plus vite pendant les 10 dernières secondes avant la fenêtre suivante.
- **SELECT** coupe ou rallume les LED.

## Pourquoi un relais

Les données viennent du dashboard Firedancer de Staking Facilities (`wss://fd-mainnet.stakingfacilities.com/websocket`). Le badge ne peut pas s'y brancher directement :

- À la connexion, le dashboard envoie deux leader schedules d'environ 370 Ko chacun. Le badge coupe tout message de plus de 4 Ko.
- Ensuite, il envoie des centaines de messages par seconde, alors que le badge n'en met que 8 en attente.
- Tant qu'un websocket est ouvert sur le badge, `rpc` et `http` sont coupés.

`server.ts` (Bun) suit donc ce flux et garde le leader schedule. Il repère les slots de Galaxy et envoie au badge des messages de moins de 250 octets :

- un `info` toutes les 5 s ;
- un `slot` pour chaque slot de Galaxy, au moment où il est produit ou skippé.

La commission, le stake exact et l'état delinquent viennent de `getVoteAccounts`, parce que le topic `peers` du dashboard laisse ces champs à 0.

## Mise en route

1. **Héberger le relais** derrière HTTPS sur le port 443, à un nom de domaine à toi. Le badge n'ouvre que du `wss://` sur le port 443. Un petit VPS avec Caddy, Fly.io ou un tunnel Cloudflare suffit.

   ```sh
   PUBLIC_URL=https://galaxy.ton-domaine.xyz PORT=8080 bun server.ts
   ```

   Variables disponibles :
   - `FD_WS` : l'adresse du dashboard ;
   - `IDENTITY` et `VOTE` : les clés du validateur (Galaxy par défaut) ;
   - `RPC_URL` : le RPC utilisé (`api.mainnet-beta.solana.com` par défaut) ;
   - `APP` : l'identifiant de l'app (`galaxy-live` par défaut).

   `GET /status` renvoie l'état courant en JSON, pratique pour vérifier que tout tourne.

2. **Mettre ton domaine** dans `main.lua` (la variable `RELAY`) et dans `app.json` (le champ `hosts`).

3. **Installer l'app** : va sur `/apps/submit`, glisse le dossier, puis clique sur **Run on badge**. Sans compte, ça ouvre un test run de 12 h. Pour la garder, publie-la.

   N'envoie que `main.lua` et `app.json`. `server.ts` et ce README partiraient dans l'app comme fichiers embarqués.

Le relais vérifie le ticket signé que le badge envoie à l'ouverture du websocket (même code que l'exemple officiel `wifi-room`). Seule l'app `galaxy-live` peut donc s'y connecter. `DEV_NO_TICKET=1` désactive cette vérification, pour les tests en local uniquement.

## Testé

- **Le relais** a tourné contre le vrai flux Firedancer. Il a trouvé le leader schedule de Galaxy : 1 730 fenêtres, soit 6 920 slots par epoch, comme `getLeaderSchedule`. Il a émis chaque slot de Galaxy environ 250 ms après le précédent.
- **L'app** a tourné dans Lua 5.5 avec des modules badge simulés, branchée sur ce relais. Sur une vraie fenêtre leader (slots 469 348 536 à 469 348 539), on a eu le compte à rebours, la respiration des LED latérales, le remplissage de la barre, le flash et le fondu.
- **Pas encore testé** sur un vrai badge, ni dans l'émulateur du site.

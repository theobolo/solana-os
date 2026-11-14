# Galaxy Live

Le cluster Solana qui produit ses blocs, en direct sur le badge, avec le validateur Galaxy au premier plan. C'est une version au format du badge du dashboard Firedancer, signée @ghosty.

![Galaxy leader](preview/c_slot2.png)

Ces images viennent d'une prévisualisation, pas du badge lui-même. Le vrai `main.lua` tourne dans Lua 5.5, et les objets `ui` sont redessinés avec les couleurs du thème du badge. Les données viennent du flux réel. Les polices sont des approximations. Animation : [preview/galaxy_live_2x.gif](preview/galaxy_live_2x.gif).

## Vue LIVE

- **Carrousel de leaders** : cinq fenêtres leader, le passé à gauche et le futur à droite. La fenêtre en cours a un cadre vert.
  - Chaque carte affiche le validateur et ses 4 slots.
  - Le slot en cours se remplit pendant qu'il est produit (environ 200 ms en Alpenglow). Il passe ensuite au bleu (completed), au violet clair (notarized), puis au vert (rooted), ou au rose barré s'il est skippé.
  - Les cartes glissent quand le leader suivant prend la main. Galaxy a une carte violette avec un liseré en dégradé Solana.
- **TX / SLOT** : une barre par slot du cluster, qui défile en continu au rythme des slots. Le vert représente les succès, le rose les échecs. Les slots de Galaxy sont en dégradé Solana sur fond violet. Le slot en cours entre par la droite.
- **Panneau Galaxy** : le stake actif, le rang, la part du réseau, la commission, un anneau de progression de l'epoch et le compte à rebours jusqu'à la prochaine fenêtre. Le cadre pulse en rose pendant les 10 dernières secondes. Pendant la fenêtre, il affiche « LEADER NOW » avec les transactions et les frais au fil des slots.

## Vue GALAXY (LEFT / RIGHT)

- Une frise des fenêtres leader de Galaxy sur les 10 prochaines minutes.
- Un grand compte à rebours.
- Le nombre de blocs produits sur ceux prévus pour l'epoch, avec le taux de skip.
- Un histogramme des 16 derniers blocs (en transactions).

## LED

- **Les 6 du haut** : elles se remplissent slot par slot pendant que Galaxy est leader, du violet au vert, ou en rouge pour un skip. À la fin de la fenêtre, elles font un flash puis s'éteignent en fondu.
- **Les 2 du côté** : elles respirent de plus en plus vite pendant les 10 secondes qui précèdent la fenêtre suivante. En mode « full », elles clignotent aussi à chaque slot du cluster.
- **SELECT** fait défiler les modes : full, Galaxy seulement, éteint.

## Le relais (`server.ts`)

Le badge ne peut pas se brancher directement sur le dashboard Firedancer de Staking Facilities (`wss://fd-mainnet.stakingfacilities.com/websocket`) :

- À la connexion, le dashboard envoie deux leader schedules d'environ 370 Ko chacun. Le badge coupe tout message de plus de 4 Ko.
- Ensuite, il envoie des centaines de messages par seconde.

Le relais suit donc ce flux et envoie au badge, toutes les 100 ms, une image complète d'environ 450 octets : les 5 fenêtres du carrousel avec l'état et les transactions de chaque slot, le slot estimé et le TPS. Comme chaque image est complète, une image perdue ne casse rien. Il envoie aussi :

- un message `slot` pour chaque slot de Galaxy ;
- un `info` toutes les 2 s : stake, rang, epoch, blocs, skips, les 24 prochaines fenêtres et les 16 derniers blocs.

Au total, cela fait environ 3 Ko/s vers le badge. La commission, le stake exact et l'état delinquent viennent de `getVoteAccounts`, parce que le topic `peers` du dashboard laisse ces champs à 0.

## Mise en route

1. **Héberger le relais** derrière HTTPS sur le port 443, à un nom de domaine à toi. Le badge n'ouvre que du `wss://` sur le port 443. Un petit VPS avec Caddy, Fly.io ou un tunnel Cloudflare suffit.

   ```sh
   PUBLIC_URL=https://galaxy.ton-domaine.xyz PORT=8080 bun server.ts
   ```

   Variables disponibles :
   - `FD_WS` : l'adresse du dashboard ;
   - `IDENTITY` et `VOTE` : les clés du validateur (Galaxy par défaut) ;
   - `RPC_URL` : le RPC utilisé ;
   - `APP` : l'identifiant de l'app (`galaxy-live` par défaut) ;
   - `FRAME_MS` : l'intervalle entre deux images (100 par défaut).

   `GET /status` renvoie l'état courant en JSON, pratique pour vérifier que tout tourne.

2. **Mettre ton domaine** dans `main.lua` (la variable `RELAY`) et dans `app.json` (le champ `hosts`).

3. **Installer l'app** : va sur `/apps/submit`, puis envoie seulement `main.lua` et `app.json`. Le reste du dossier partirait dans l'app comme fichiers embarqués. Clique ensuite sur **Run on badge** : ça ouvre un test run de 12 h. Pour la garder, publie-la.

Le relais vérifie le ticket signé que le badge envoie à l'ouverture du websocket, avec le même code que l'exemple officiel `wifi-room`. `DEV_NO_TICKET=1` désactive cette vérification, pour les tests en local uniquement.

## Testé

- **Le relais** a tourné contre le vrai flux Firedancer. Il trouve le leader schedule de Galaxy : 6 920 slots par epoch, comme `getLeaderSchedule`.
- **L'app** a tourné dans la prévisualisation, branchée sur ce relais, pendant une vraie fenêtre de Galaxy (slots 469 352 188 à 469 352 191). Toutes les captures viennent de ce test.
  - Au pire, une callback a coûté 32 000 instructions, pour une limite de 200 000 sur le badge.
  - Aucun message n'a dépassé 4 Ko.
- **Pas encore testé** sur un vrai badge. La fluidité réelle dépendra de la vitesse de l'écran SPI. Le carrousel est redessiné à chaque tick (30 ms) et l'histogramme un tick sur deux. Si ça rame, augmente ces intervalles dans `on_tick`.

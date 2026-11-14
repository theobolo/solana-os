# Validators

Une app Lua pour le badge : l'état public de tes validateurs Solana.

Pour chaque compte de vote, elle affiche :

- l'identité (le node) ;
- la commission ;
- `OK` s'il vote, ou `DELINQ` si son dernier vote a plus de 128 slots de retard ;
- le solde du compte de vote et celui de l'identité.

En haut de l'écran, elle affiche l'epoch et sa progression. Les LED passent au vert quand tous les validateurs votent, au rouge dès qu'un décroche. SELECT rafraîchit, et l'app se rafraîchit aussi toute seule toutes les 2 minutes.

## Configurer

Dans `main.lua`, remplis `VALIDATORS` avec un nom court et l'adresse du **compte de vote** de chaque validateur (pas l'identité) :

```lua
local VALIDATORS = {
  { name = "Main", vote = "..." },
  { name = "Testnet-ish", vote = "..." },
}
```

Avec 5 validateurs, un rafraîchissement fait environ 21 appels, pour une limite de 30 appels `rpc` par minute et par badge.

## Installer

1. Va sur `/apps/submit` du site du badge, depuis Chrome ou Edge sur ordinateur.
2. Glisse le dossier dans l'éditeur, puis clique sur **Run on badge** (en USB-C). Le badge doit avoir une microSD et Solana OS 0.5.2 ou plus récent.

L'appel `rpc` exige soit une app publiée, soit un « test run » (12 h, compte connecté). Pour l'avoir en permanence, publie-la : elle peut rester privée tant qu'un organisateur ne l'a pas validée.

## Comment ça marche

`getVoteAccounts` ne fait pas partie des méthodes `rpc` autorisées sur le badge. L'app lit donc elle-même le début du compte de vote, avec `getAccountInfo` et un `dataSlice` en base64. Elle gère les versions V1_14_11, V3 et V4 (SIMD-0185, la commission en points de base). Elle lit ensuite le dernier slot voté à la fin du vecteur `votes`.

Le stake actif n'est pas affiché : il ne se lit pas avec les méthodes autorisées. Il faudrait passer par `http` vers une API externe.

L'app a été testée sur mainnet contre `getVoteAccounts` (identité, commission, dernier vote, delinquent), dans un Lua 5.5 avec des modules badge simulés. Elle n'a pas encore tourné sur un vrai badge.

# Fork HomeLab

- Fork : https://github.com/iitsGaMa/codenotch
- Source officielle (`upstream`) : https://github.com/vinzdg/codenotch
- Branche maintenue : `homelab`.
- Adaptations : quotas CCS distants, un indicateur par pool, détail par compte.

La configuration et les identifiants restent dans `~/.config/codenotch/` et hors
Git. Voir la section CCS du README. Les fichiers installés actuellement sur les
Mac ne sont pas mis à jour par un simple push GitHub.

## Intégrer les nouveautés

Avec un arbre de travail propre :

```sh
git switch homelab
git fetch upstream --tags
git switch -c update/codenotch-upstream
git merge upstream/main
make test
git push -u origin HEAD
```

Résoudre les conflits, vérifier les pools et fusionner la branche dans `homelab`.
Ne pas utiliser une synchronisation qui écrase la branche personnalisée.

## Construire et installer

Lancer **Actions → Homelab build → Run workflow**, branche `homelab`.
Le workflow compile pour Apple Silicon, exécute les tests liés aux adaptations et
produit l'artefact `Codenotch-homelab-<commit>`. Il ne publie pas de release.
La compilation est signée ad hoc, sans notarisation Apple ; macOS peut demander
une autorisation d'ouverture. Les builds officiels signés restent distincts.

Installation locale depuis les sources : `make install` (remplace l'application).
Sauvegarder l'application précédente avant de l'utiliser pour pouvoir revenir en arrière.

Le drapeau `HomelabFork` du bundle bloque les mises à jour Sparkle officielles,
y compris la vérification manuelle. Une mise à jour du fork nécessite une fusion,
un build et une installation. Aucun serveur de mise à jour automatique spécifique
au fork n'est configuré. Les autres workflows upstream restent désactivés côté
GitHub ; seul le build manuel du fork est activé.

## Dépenses supplémentaires

Les montants proviennent du champ `spend` de Claude, avec sa devise et son unité.
Le plafond de dépenses ne représente pas des crédits achetés. Un solde absent
reste non communiqué ; les champs internes non identifiés ne sont pas utilisés.

Le champ `iguana_necktie` est affiché séparément comme crédits promotionnels Cloud,
suivant l’interprétation de [CodexBar](https://github.com/steipete/CodexBar/blob/79831b47517f3e3e340886be63157f582ab13d41/Sources/CodexBarCore/Providers/Claude/ClaudeCloudCreditsSnapshot.swift).
Ses montants sont déjà en USD et sa date est une expiration, pas une remise à zéro.
Ils ne sont additionnés ni au solde Console ni aux quotas du pool.

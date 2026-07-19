# BLON AWS Infrastructure

Infrastructure as Code de **BLON ENTERPRISES**.

Le premier template construit le socle du compte `BLON-NonProd` dans la region
AWS Europe (Paris), `eu-west-3`.

## Ressources creees

- un VPC `10.20.0.0/16` ;
- deux subnets publics dans deux zones de disponibilite ;
- deux subnets prives reserves aux evolutions futures ;
- une Internet Gateway ;
- une table de routage publique avec `0.0.0.0/0` vers Internet ;
- une table de routage privee sans NAT Gateway ;
- un Security Group ouvrant uniquement HTTP 80 et HTTPS 443 ;
- un role IAM EC2 limite a Systems Manager ;
- un profil d'instance IAM ;
- une EC2 Amazon Linux 2023 x86_64 `t3.small` ;
- Docker et Docker Compose installes par AWS Systems Manager State Manager ;
- un volume EBS `gp3` chiffre de 30 Gio ;
- une Elastic IP associee a l'EC2.

Le template n'ouvre pas SSH 22. L'administration se fait avec AWS Systems
Manager Session Manager.

## Ce qui n'est pas encore cree

- NAT Gateway ;
- Load Balancer ;
- RDS PostgreSQL ;
- Route 53 et nom de domaine ;
- certificat HTTPS ;
- applications conteneurisees ;
- sauvegardes S3 ;
- CloudWatch Agent ;
- ressources de production.

## Arborescence

```text
blon-aws-infrastructure/
├── cloudformation/
│   ├── nonprod-core.yaml
│   └── parameters/
│       └── nonprod.json
├── .gitignore
└── README.md
```

## Pre-requis

1. Se connecter au portail AWS IAM Identity Center.
2. Ouvrir le compte `BLON-NonProd` avec `BLON-AdministratorAccess`.
3. Selectionner `eu-west-3`.
4. Configurer AWS CLI avec IAM Identity Center.

Exemple de profil AWS CLI :

```bash
aws configure sso --profile blon-nonprod
aws sso login --profile blon-nonprod
aws sts get-caller-identity --profile blon-nonprod
```

La commande `get-caller-identity` doit confirmer que le profil pointe bien vers
le compte `BLON-NonProd`. Aucun identifiant de compte ne doit etre code en dur
dans ce depot afin de conserver sa reutilisabilite.

## Validation locale

```bash
aws cloudformation validate-template \
  --template-body file://cloudformation/nonprod-core.yaml \
  --region eu-west-3 \
  --profile blon-nonprod
```

## Deploiement par AWS CLI

Depuis la racine du depot :

```bash
aws cloudformation deploy \
  --template-file cloudformation/nonprod-core.yaml \
  --stack-name blon-nonprod-core \
  --parameter-overrides file://cloudformation/parameters/nonprod.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-3 \
  --profile blon-nonprod \
  --no-fail-on-empty-changeset
```

Pour afficher les sorties :

```bash
aws cloudformation describe-stacks \
  --stack-name blon-nonprod-core \
  --query "Stacks[0].Outputs" \
  --region eu-west-3 \
  --profile blon-nonprod
```

## Deploiement par la console AWS

1. Ouvrir CloudFormation dans `BLON-NonProd`.
2. Selectionner la region `Europe (Paris) eu-west-3`.
3. Choisir **Creer une pile** puis **Avec de nouvelles ressources**.
4. Charger `cloudformation/nonprod-core.yaml`.
5. Nommer la pile `blon-nonprod-core`.
6. Conserver les parametres proposes.
7. Autoriser la creation des ressources IAM nommees.
8. Creer la pile et attendre `CREATE_COMPLETE`.

## Acces a l'instance

Le template ne cree ni paire de cles ni acces SSH. Il utilise exclusivement
AWS Systems Manager Session Manager. Cette decision evite de placer une cle
privee dans CloudFormation ou Git et maintient le port 22 ferme.

## Docker

Le template installe Docker sur l'instance avec une association AWS Systems
Manager State Manager fondee sur le document `AWS-RunShellScript`. Les commandes
sont idempotentes : Docker est installe avec `dnf` seulement s'il est absent,
puis `docker.service` est active, demarre et verifie.

Le paquet `docker-compose-plugin` n'etant pas disponible dans les depots
Amazon Linux 2023 utilises par l'instance, le template installe manuellement le
plugin Docker Compose officiel. La version `v5.3.1` est epinglee globalement
dans `/usr/local/lib/docker/cli-plugins/docker-compose`, pour `x86_64`
uniquement. Sa somme SHA-256 officielle est verifiee avant installation. Si le
binaire deja installe possede la somme attendue, il n'est pas telecharge de
nouveau.

L'utilisateur `ssm-user` n'est pas ajoute au groupe `docker`. Utiliser `sudo`
pour administrer Docker depuis une session Systems Manager :

```bash
sudo docker --version
sudo docker info
sudo docker compose version
```

Pour verifier l'etat de l'association depuis AWS CLI :

```powershell
$associationId = aws ssm list-associations `
  --association-filter-list "key=AssociationName,value=blon-nonprod-docker-install" `
  --query "Associations[0].AssociationId" `
  --output text `
  --region eu-west-3 `
  --profile blon-nonprod

aws ssm describe-association `
  --association-id $associationId `
  --query "AssociationDescription.{Status:Overview.Status,LastExecutionDate:LastExecutionDate,Targets:Targets}" `
  --region eu-west-3 `
  --profile blon-nonprod
```

Le statut attendu est `Success`. En cas d'echec, consulter l'historique des
executions de l'association dans Systems Manager, sous State Manager.

## Free Tier et credits

Le type par defaut est `t3.small`, actuellement liste parmi les instances
eligibles aux offres Free Tier fondees sur les credits. Verifier l'indication
affichee par AWS avant chaque deploiement. Les credits, leur duree et leur solde
restent propres au compte et a l'offre AWS active.

L'Elastic IP publique est facturable. Elle doit etre supprimee avec la stack si
elle n'est plus utilisee.

## Mise a jour

Modifier le template, valider les changements, puis relancer la commande
`aws cloudformation deploy`. CloudFormation calcule et applique la difference.

Pour les changements sensibles, creer d'abord un Change Set dans la console ou
avec AWS CLI.

## Suppression

L'instance active la protection contre l'arret et la terminaison. Avant de
supprimer la stack, desactiver ces protections sur l'instance ou les retirer du
template par une mise a jour de stack.

```bash
aws cloudformation delete-stack \
  --stack-name blon-nonprod-core \
  --region eu-west-3 \
  --profile blon-nonprod
```

La suppression detruit l'EC2, son volume racine et l'Elastic IP. Ne jamais
supprimer la stack lorsqu'elle contient des donnees non sauvegardees.

## Strategie Git

Branches recommandees :

```text
main              version stable de l'infrastructure
develop           integration des changements
feature/<sujet>   evolution isolee
```

Ne jamais versionner :

- mots de passe ;
- access keys AWS ;
- fichiers `.pem` ;
- secrets applicatifs ;
- fichiers `.env` reels ;
- exports de base de donnees.

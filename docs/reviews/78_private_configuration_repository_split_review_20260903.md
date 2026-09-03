# Niezależny review Planu 78

Zakres: `docs/plans/78_private_configuration_repository_split_20260903.md` względem aktualnego drzewa repozytorium.
Sprawdzono publiczne workflow, `scripts/arcp`, `sync-build-deploy.sh`, `arcp-release-artifact.sh`, walidator i lokalne
ignorowane artefakty. Review nie ocenia ani nie ujawnia wartości konfiguracji.

## Potwierdzony stan

- `myconf/` ma 50 śledzonych plików; pierwszy commit jest osiągalny z `main`, `release/edge` i pięciu tagów. Samo
  usunięcie bieżącego drzewa nie usuwa wcześniejszej publikacji.
- `sync-build-deploy.sh` nadal uruchamia walidację `myconf` dla zwykłego `build`, a potem wymaga tokenu ngrok;
  `scripts/arcp build local` deleguje właśnie do tej ścieżki. `arcp-release-artifact.sh` ma osobne, niezależne od
  konfiguracji operacje `download`/`verify`, ale w `deploy` ma aliasy, adres i ścieżkę `myconf` wpisane w kod.
- Publiczny channel-release nie jest w całości secretless: osobny job używa `NGROK_AUTHTOKEN`, a podpisywanie używa
  keystore i haseł. Secretless jest statyczny build, nie cały release workflow.
- Poza trzema `.env.secrets` lokalne `myconf/[REDACTED_DEVICE_ALIAS]/cloudflare/` zawiera ignorowane `terraform.tfstate`, zapisany
  `tfplan` i `.terraform/`. Plan wymienia w kroku przenoszenia tylko `.env.secrets`.

## Must-fix

### B1 — Sekwencja commit/push ma cykl i nie dowodzi stanu końcowego

`schemas.lock.json` z prywatnego commitu 3 nie może być zweryfikowany w GitHub Actions przeciw nieopublikowanemu
publicznemu commitowi 2. Jeśli zostanie przypięty do commitu 2, nadal wskazuje checkout zawierający `myconf/`, więc
nie dowodzi końcowej granicy po commicie 4. Plan nie ma też jawnego kroku utworzenia `profile.json` dla każdego
zaimportowanego profilu.

Wymagana kolejność: (1) prywatny skeleton z bezpiecznym importem, (2) opublikowany publiczny adapter/schema, nadal bez
usuwania `myconf`, (3) migracja wszystkich prywatnych profili, wrappers i lock do pełnego publicznego SHA oraz zielona
prywatna walidacja/check, (4) publiczne usunięcie i sanityzacja oraz zielone publiczne CI/release dry-run, (5) aktualizacja
prywatnego locka do końcowego publicznego SHA i ponowne dowiedzenie pracy bez `myconf`. Każdy etap ma własny stop gate;
nie wystarcza zbiorcze „push private, potem public”.

### B2 — `ARCP_CONFIG_ROOT` musi być rozwiązywany leniwie, per komenda

Plan mówi o „all owner utilities” i o podawaniu fixture root przez publiczne CI. To może zachować obecną, błędną
zależność zwykłego build/release od konfiguracji urządzeń.

Resolver ma być wymagany wyłącznie dla `check`, `deploy`, `rollback`, części deploymentowej `all`,
`arcp-release-artifact deploy` i zachowanych helperów urządzeń. `sync`, `channel-info`, zwykły/channel `build`,
`scripts/arcp build/release`, artifact `download`/`verify`, ledger, sign i publish nie mogą nawet próbować rozwiązać
`--config-root`, `ARCP_CONFIG_ROOT` ani fixture. Publiczne fixtures należy podawać tylko testom kontraktu profili.
Testy muszą uruchamiać wszystkie ścieżki build/release z nieustawionym rootem i dowodzić braku odczytu `myconf`.

### B3 — Granica public/private CI i słowo „secretless” są niedookreślone

Nie wolno uruchamiać kodu z dowolnego publicznego refa przy dostępie do prywatnej konfiguracji lub sekretów. Prywatna
walidacja ma akceptować wyłącznie pełny SHA z zaufanej gałęzi/tagu właściciela; część bez sekretów i bez uprawnień
deploy należy oddzielić od ręcznego joba decrypt/apply chronionego environment approval. Żaden publiczny PR ani
`pull_request_target` nie może wybrać wykonywanego SHA. Prywatne snapshoty nie mogą trafiać do artifacts, cache ani
step summary.

W publicznym workflow trzeba mówić „niezależny od prywatnej konfiguracji”, a nie „release secretless”. Obecne
minimalne sekrety ngrok/signing mogą pozostać tylko jako jawnie sklasyfikowana, istniejąca granica release; publiczny
workflow nie może dostać tokenu/PAT do prywatnego repo ani checkoutować prywatnej konfiguracji.

### B4 — Migracja sekretów pomija istniejące ignorowane artefakty

Import nie może być rekurencyjnym skopiowaniem `myconf` zakończonym `git add`. Najpierw prywatne `.gitignore` i reguły
tracked-file, potem import wyłącznie publicznie śledzonej listy; wszystkie ignorowane pliki trzeba osobno zinwentaryzować
bez wartości. `.env.secrets`, Terraform state/plan i inne runtime artefakty należy przenieść do ignorowanego katalogu
mode 0600 albo zaszyfrowanego backupu, z audytem indexu przed pierwszym pushem. Provider cache nie jest konfiguracją i
nie powinien być importowany.

Brak rotacji jest dopuszczalny tylko pod warunkiem stop gate: jeśli inventory/history scan wykryje faktyczny sekret,
migracja nie może uznać „credentials unchanged” za sukces; należy przerwać i uruchomić osobno autoryzowany incident
response/rotation. Sam GitHub secret scanning nie pokrywa wszystkich formatów.

### B5 — Rollback ponownie opublikowałby dane

„Revert the public adapter/removal commits normally” odtworzyłby `myconf` w bieżącym publicznym drzewie i złamał cel
planu. Po publicznym usunięciu rollback musi być forward-only: poprawka adaptera, przypięcie prywatnego repo do ostatniego
działającego publicznego SHA i ewentualne użycie backupu w izolowanym lokalnym checkoutcie. Nie wolno pushować
odtworzonego `myconf`, przesuwać tagów ani przepisywać historii.

### B6 — Sanityzacja musi obejmować wszystkie śledzone pliki

Faza 4 wymienia scripts/plans/reviews/docs, ale realny alias występuje także w `app/src/debug`. Inventory i polityka
końcowa muszą objąć całe `git ls-files` (z uzasadnionymi, wąskimi allowlistami), inaczej kryterium „no named device
inventory” nie jest dowiedzione.

## Polityka historii

Zakaz domyślnego history rewrite, przesuwania tagów i odtwarzania wydań jest poprawny. Raport ekspozycji gałęzi,
tagów, releases, Actions artifacts i PR references powinien być obowiązkowym closeoutem, bez twierdzenia, że bieżące
usunięcie cofnęło wcześniejszą publikację.

## Werdykt

**NIE ZATWIERDZAĆ DO IMPLEMENTACJI — approve after changes.** Kierunek architektury jest właściwy, ale B1–B6 muszą
zostać wpisane do planu przed migracją, zwłaszcza etapowe pinowanie SHA, leniwa granica config-root i bezpieczny rollback.

## Re-review po poprawkach

Zaktualizowany plan usuwa wszystkie sześć blockerów:

- **B1 — usunięty:** rollout ma teraz pięć osobnych stop gates, publiczny adapter jest publikowany przed prywatnym
  pinem, a końcowy prywatny commit aktualizuje lock do publicznego SHA już bez `myconf`. Dodano też obowiązkowe
  `profile.json` dla każdego celu. Drobna niespójność redakcyjna pozostaje między Phase 1 pkt 5 a rollout pkt 3 co do
  momentu tworzenia profili; sekwencja rollout jest jednak jednoznaczna i powinna być traktowana jako wiążąca.
- **B2 — usunięty:** resolver jest leniwy i ma zamkniętą listę device-only commands; zwykłe build/release oraz
  download/verify mają testowany kontrakt działania bez root i bez `myconf`.
- **B3 — usunięty:** plan poprawnie odróżnia secretless static build od całego release, zabrania private-repo PAT w
  publicznym workflow, ogranicza prywatne wykonanie do allowlisted full SHA i rozdziela validation od manual decrypt/apply.
- **B4 — usunięty:** import jest tracked-only po instalacji ignore/policy; `.env.secrets`, Terraform state/plan i cache
  mają osobne, bezpieczne reguły, audit indexu i stop gate prowadzący do osobnej rotacji po wykryciu sekretu.
- **B5 — usunięty:** rollback jest forward-only i jawnie zabrania przywrócenia `myconf`, force-push, ruchu tagów oraz
  ponownej publikacji wcześniejszych releases.
- **B6 — usunięty:** inventory, sanityzacja i końcowa polityka obejmują całe `git ls-files`, w tym `app/src/debug`.

Zakaz automatycznej rotacji i history rewrite pozostał właściwie ograniczony: faktyczny sekret zatrzymuje plan i
uruchamia osobno autoryzowaną reakcję, a raport historycznej ekspozycji jest obowiązkowym closeoutem.

**Werdykt re-review: ZATWIERDZIĆ DO IMPLEMENTACJI. B1–B6 są zamknięte; pozostaje wyłącznie nieblokująca korekta
redakcyjna kolejności tworzenia `profile.json`.**

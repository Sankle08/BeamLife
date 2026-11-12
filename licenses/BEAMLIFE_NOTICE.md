# BeamLife Career

BeamLife Career is a modified version of **RLS Career Overhaul v2.8.0** by RLS Studios and contributors
(https://github.com/RLS-Modding/rls_career_overhaul), built for BeamNG.drive 0.40.

RLS Career Overhaul is licensed under the GNU Affero General Public License v3.0 only, with a BeamNG
additional permission (see the upstream repository's LICENSE and LICENSING.md). BeamLife Career is distributed
under the same terms. Files derived from BeamNG.drive keep their own licence (bCDDL v1.1), and bundled
third-party components keep theirs (see the other files in this folder and upstream's
THIRD_PARTY_NOTICES.md).

This is an unofficial fork. It is not made, endorsed or supported by RLS Studios. Do not report its
problems upstream.

## Changes made to RLS Career Overhaul (November 2026)

Modified upstream files:

- `lua/ge/extensions/overhaul/integration/services/police.lua`: pursuit levels escalate later
  (score levels 150 / 1200 / 4200) and speeding only counts from 35 km/h over the limit.
- `lua/ge/extensions/overhaul/career/police/playerDriving.lua`: smaller fine when the player pulls
  over at pursuit level 1.
- `lua/ge/extensions/overhaul/career/police/enforcement.lua`: an evaded pursuit no longer sells the
  dashcam footage at once; the clip goes to the DashTube app instead.

- `lua/ge/extensions/overhaul/career/police/speedTraps.lua`: lower speed-camera fines.
- `lua/ge/extensions/overhaul/jobs/taxi/taxi.lua` and `.../views/phone/PhoneTaxi.vue`: an accepted ride can
  be cancelled for a fee of 2-5% of the fare.
- `lua/ge/extensions/overhaul/phone/phone.lua` and `.../views/phone/PhoneShell.vue`: the phone can be used
  while driving and is operated with the mouse only.
- `lua/ge/extensions/overhaul/career/garage/garageManager/ownership.lua` and
  `levels/rls_west_coast/facilities/facilities.facilities.json`: the free starting home is drawn from
  homes near the city centre.

Added files (the BeamLife layer):

- `lua/ge/extensions/beamlife/`: core services, WorkDay shift jobs, Bicos gigs, the two freight
  carriers, Business passive income, police tuning with the DashTube dashcam channel, and R2F Club.
- `ui/ui-vue/mods/beamlife/`: the phone apps for the above and the clock/date bar.
- `gameplay/overhaul/career/modules/beamlife_*.json` and `gameplay/overhaul/phone/apps/beamlife-*.json`:
  the manifests that register those modules and apps with the Overhaul.

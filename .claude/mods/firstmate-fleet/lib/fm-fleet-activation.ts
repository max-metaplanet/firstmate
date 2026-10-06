// The firstmate-fleet mod's activation rule, kept apart from the engine so the exact
// opt-in is provable under Node as well as inside Claude Code.
//
// Claude Code loads a mod's hooks module on its own terms, so a module that wants to be
// a complete no-op until the captain asks for it must gate every handler itself. This
// mod is new, so it carries no deprecated alias: the one firstmate-owned name
// `FM_FLEET_ENABLED` decides, and only the exact value `1` activates. Anything else -
// unset, empty, `0`, `true`, a name that cannot be read - leaves the mod inert, which is
// the safe reading for a gate whose failure mode would otherwise be an unasked pane and
// a shell-out on a timer.
//
// Claude Code's static analysis requires a literal name at the `$.env.get` call, so the
// name itself is spelled in `hooks/register.ts`; `claude plugin validate --strict` is
// what reports the names a module reads, and tests/fm-fleet-mod-plugin.test.sh pins that
// report to this one name.

/** Whether the activation flag's value as read activates the mod. */
export function fleetActivationFromEnv(value: string | undefined): boolean {
  return value === "1";
}

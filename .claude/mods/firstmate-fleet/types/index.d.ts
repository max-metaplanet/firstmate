// The values firstmate-fleet keeps in `$.state`, where they survive a hot reload.
declare module "claude-code" {
  interface PluginState {
    "firstmate-fleet": {
      /** session.start's own isInteractive: false in a `-p` run, where nothing drawn is seen. */
      canDraw: boolean;
    };
  }
}

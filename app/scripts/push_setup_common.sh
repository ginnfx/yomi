#!/bin/sh
# Shared by APNs and FCM setup; preserve the other provider's configuration.
sync_push_settings() {
  PUSH_WORK=$1
  shift
  ssh homelab "if [ -f $REMOTE_DIR/push.env ]; then cat $REMOTE_DIR/push.env; fi" > "$PUSH_WORK/push.env"
  scp -O "homelab:$REMOTE_DIR/start.sh" "$PUSH_WORK/start.sh"
  python3 "$SCRIPT_DIR/merge_push_settings.py" "$PUSH_WORK/push.env" "$PUSH_WORK/start.sh" "$@"
  scp -O "$PUSH_WORK/push.env" "homelab:$REMOTE_DIR/push.env.new"
  scp -O "$PUSH_WORK/start.sh" "homelab:$REMOTE_DIR/start.sh.new"
  ssh homelab "chmod 600 $REMOTE_DIR/push.env.new && chmod 755 $REMOTE_DIR/start.sh.new && cp $REMOTE_DIR/start.sh $REMOTE_DIR/start.sh.before-push && mv $REMOTE_DIR/push.env.new $REMOTE_DIR/push.env && mv $REMOTE_DIR/start.sh.new $REMOTE_DIR/start.sh"
}

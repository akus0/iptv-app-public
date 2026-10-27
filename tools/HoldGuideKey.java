// Shell-only remote repeat diagnostic. Compile against android.jar and dex with d8.
// Push the DEX to /data/local/tmp/iptv-guide-input.dex; profile_tv_hold.py invokes it.
// Only Up/Down are allowed; it always sends a release and cannot select a stream.
import android.os.SystemClock;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.InputDevice;
import java.lang.reflect.Method;

public class HoldGuideKey {
  public static void main(String[] args) throws Exception {
    int key = Integer.parseInt(args[0]);
    long duration = Long.parseLong(args[1]);
    if ((key != 19 && key != 20) || duration < 1 || duration > 60000) throw new IllegalArgumentException();
    Class<?> type;
    try {type = Class.forName("android.hardware.input.InputManagerGlobal");}
    catch(ClassNotFoundException e) {type = Class.forName("android.hardware.input.InputManager");}
    Object manager = type.getMethod("getInstance").invoke(null);
    Method inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
    long start = SystemClock.uptimeMillis();
    int count = 0;
    try {
      do {
        long now = SystemClock.uptimeMillis();
        KeyEvent event = new KeyEvent(start, now, KeyEvent.ACTION_DOWN, key, count, 0, -1, 0,
            count == 1 ? KeyEvent.FLAG_LONG_PRESS : 0, InputDevice.SOURCE_DPAD);
        inject.invoke(manager, event, 2);
        count++;
        SystemClock.sleep(count == 1 ? 450 : 50);
      } while (SystemClock.uptimeMillis() - start < duration);
    } finally {
      inject.invoke(manager, new KeyEvent(start, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP,
          key, 0, 0, -1, 0, 0, InputDevice.SOURCE_DPAD), 2);
    }
    System.out.println("Released " + count + " remote events");
  }
}

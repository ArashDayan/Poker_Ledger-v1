package com.pokerledger.app

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * Uses FlutterFragmentActivity rather than FlutterActivity because the
 * App Lock feature (local_auth) shows the system BiometricPrompt, which
 * is a Fragment and therefore requires a FragmentActivity host.
 *
 * With plain FlutterActivity the biometric prompt throws
 * "no_fragment_activity" at runtime — the app still launches, so this is
 * the kind of mistake that only shows up the first time a user tries to
 * unlock. Changing the base class is the entire fix and affects nothing
 * else about how Flutter starts.
 */
class MainActivity : FlutterFragmentActivity()

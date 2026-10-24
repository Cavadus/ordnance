/**
 * @file Protocol error code -> friendly English message table.
 *
 * Codes are defined in docs/development/bridge-protocol.md ("Errors"
 * section). Keep this table in sync with that document.
 */
(function initErrors(root) {
  'use strict';

  const DDMM = (root.DDMM = root.DDMM || {});

  /** @type {Record<string, string>} */
  const ERROR_MESSAGES = {
    APP_NOT_RUNNING: "Ordnance didn't start in time. Open Ordnance, then try again.",
    NATIVE_HOST_MISSING: "Ordnance isn't installed (or isn't set up for this browser). Get Ordnance, then try again.",
    BAD_REQUEST: 'Ordnance rejected that request as malformed. This is an Ordnance extension bug -- please report it.',
    UNSUPPORTED: 'This version of the Ordnance extension is too old (or too new) for your Ordnance app. Try updating one of them.',
    FORBIDDEN_ORIGIN: "Ordnance didn't recognize this browser extension. Try reinstalling the Ordnance extension.",
    DECLINED: 'You chose not to install this mod.',
    NOT_ARCHIVE: "That file isn't a mod archive Ordnance recognizes (zip, 7z or rar).",
    UNSAFE_ARCHIVE: 'That archive failed a safety check and was not installed.',
    FILE_NOT_FOUND: "Ordnance couldn't find the downloaded file. Try downloading it again.",
    GAME_NOT_FOUND: "The mod was installed, but Ordnance couldn't find your Helldivers 2 install to deploy it. Set the game path in Ordnance.",
    DEPLOY_FAILED: 'The mod was installed, but deploying it failed. Check Ordnance for details.',
    BUSY: 'Ordnance is busy with another install right now. Try again in a moment.',
    INTERNAL: 'Something went wrong in Ordnance.',
    TIMEOUT: 'Ordnance took too long to respond.',
    DISCONNECTED: 'Lost the connection to Ordnance.',
    DOWNLOAD_FAILED: "The download didn't finish, so nothing was installed. Try again.",
  };

  /**
   * @param {string|undefined|null} code
   * @param {string} [fallbackMessage] - The `message` field from the error
   *   reply, used when `code` isn't in the table.
   * @returns {string} A friendly, English message safe to show the user.
   */
  function describeError(code, fallbackMessage) {
    if (code && ERROR_MESSAGES[code]) {
      return ERROR_MESSAGES[code];
    }
    return fallbackMessage || ERROR_MESSAGES.INTERNAL;
  }

  DDMM.errors = { ERROR_MESSAGES, describeError };
})(typeof globalThis !== 'undefined' ? globalThis : this);

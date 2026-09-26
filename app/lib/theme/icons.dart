import 'package:flutter/material.dart';

/// Toutes les icônes de l'app, nommées par leur sens. Les écrans n'utilisent
/// jamais `Icons` directement : changer de jeu d'icônes se fait ici seul.
///
/// Style des maquettes : Material, contour fin.
abstract final class MpIcons {
  // Navigation.
  static const accounts = Icons.account_balance_wallet_outlined;
  static const home = Icons.home_outlined;
  static const balance = Icons.show_chart_rounded;
  static const news = Icons.pie_chart_outline_rounded;
  static const journal = Icons.format_list_bulleted_rounded;
  static const menu = Icons.menu_rounded;
  static const more = Icons.more_horiz_rounded;
  static const chevronDown = Icons.keyboard_arrow_down_rounded;
  static const add = Icons.add_rounded;
  static const check = Icons.check_rounded;
  static const robot = Icons.smart_toy_outlined;
  static const power = Icons.power_settings_new_rounded;
  static const settings = Icons.settings_outlined;
  static const next = Icons.chevron_right_rounded;
  static const close = Icons.close_rounded;
  static const language = Icons.translate_rounded;

  // Chiffres de l'Accueil.
  static const wallet = Icons.account_balance_wallet_outlined;
  static const equity = Icons.bar_chart_rounded;
  static const floating = Icons.trending_up_rounded;
  static const margin = Icons.shield_outlined;
  static const rise = Icons.north_east_rounded;
  static const fall = Icons.south_east_rounded;
  static const flat = Icons.east_rounded;
  static const clock = Icons.schedule_rounded;

  // États du compte.
  static const run = Icons.play_circle_rounded;
  static const pause = Icons.pause_circle_rounded;
  static const kill = Icons.stop_circle_rounded;

  // Actions sur le robot.
  static const pauseAction = Icons.pause_rounded;
  static const stopAction = Icons.stop_rounded;
  static const relaunch = Icons.restart_alt_rounded;
  static const reset = Icons.lock_reset_rounded;

  // Signaux.
  static const ok = Icons.check_rounded;
  static const attention = Icons.warning_amber_rounded;
  static const danger = Icons.error_outline_rounded;
  static const alert = Icons.priority_high_rounded;
  static const info = Icons.info_outline_rounded;

  // Bandeau de confiance.
  static const live = Icons.check_rounded;
  static const watchdogSilent = Icons.hourglass_bottom_rounded;
  static const unreachable = Icons.cloud_off_rounded;

  // Journal.
  static const shield = Icons.shield_outlined;
  static const restart = Icons.restart_alt_rounded;
  static const killed = Icons.crop_square_rounded;

  // Actualité et marché.
  static const forex = Icons.currency_exchange_rounded;
  static const calendar = Icons.event_outlined;
  static const trendUp = Icons.trending_up_rounded;
  static const trendDown = Icons.trending_down_rounded;
  static const trendFlat = Icons.trending_flat_rounded;

  // Connexion et sécurité.
  static const telegram = Icons.send_rounded;
  static const tailscale = Icons.key_rounded;
  static const lock = Icons.lock_outline_rounded;
  static const biometrics = Icons.fingerprint_rounded;
  static const pin = Icons.pin_outlined;
  static const scanQr = Icons.qr_code_scanner_rounded;
  static const phone = Icons.smartphone_rounded;
  static const notifications = Icons.notifications_outlined;
  static const thresholds = Icons.tune_rounded;
  static const styleGuide = Icons.palette_outlined;
}

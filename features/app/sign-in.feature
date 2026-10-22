Feature: Signing in
  As someone opening Poddle
  I want to sign in and land on my Up Next
  So my shows and queue follow me between devices

  Scenario: Test sign-in lands on Up Next
    Given the listener follows "Morning Tones" with "Sunrise in A" and "Breakfast in C" in Up Next
    When they open Poddle and sign in
    Then they're on Up Next
    And the mini player shows "Sunrise in A"
    And Up Next lists "Breakfast in C"

  Scenario: Someone who isn't invited sees the invite-only message
    When "stranger@poddle.test" opens Poddle and tries to sign in
    Then the sign-in screen says "Poddle is invite-only for now."
    And they're still signed out

  Scenario: Signing out returns to sign-in and hides the library
    Given the listener follows "Morning Tones" with "Sunrise in A" in Up Next
    And they've opened Poddle signed in
    When they sign out from Profile
    Then they're still signed out
    And nothing from "Morning Tones" is on screen

  Scenario: Deleting the account signs out and removes it
    Given the listener follows "Morning Tones"
    And they've opened Poddle signed in
    When they delete their account from Profile
    Then they're still signed out
    And the listener has no account any more

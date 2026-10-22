Feature: Share pages
  As someone who's been sent a Poddle link
  I want the episode or show page to open without signing in
  So I can listen straight away, while private feeds stay private

  Background:
    Given the listener follows "Morning Tones"

  Scenario: An episode page plays and has the right link preview
    When a visitor opens the share link for "Commute in D"
    Then the link preview is for the episode "Commute in D" with the show's artwork
    And the page shows "Commute in D" from "Morning Tones"
    When they press play on the page
    Then the episode plays in the browser

  Scenario: A link with a start time starts there
    When a visitor opens the share link for "Commute in D" at 20 seconds
    Then the page says it starts at "0:20"
    And the player is at "0:20"

  Scenario: A show page lists its episodes
    When a visitor opens the share link for the show "Morning Tones"
    Then the link preview is for the show "Morning Tones"
    And the page lists the episodes "Commute in D", "Breakfast in C" and "Sunrise in A"

  Scenario: A private feed's episode is not found
    Given the listener follows "Secret Signals"
    When a visitor opens the share link for "Members Only"
    Then the page says the episode wasn't found
    And the link preview doesn't mention "Members Only"

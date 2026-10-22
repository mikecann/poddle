Feature: Downloads
  As a listener
  I want to download episodes and take back a deleted download
  So I can listen offline without losing files by mistake

  Background:
    Given the listener follows "Morning Tones" with "Sunrise in A" and "Breakfast in C" in Up Next
    And they don't auto-download
    And they've opened Poddle signed in

  Scenario: Download an episode
    Then "Breakfast in C" shows as not downloaded
    When they download "Breakfast in C" from its menu
    Then "Breakfast in C" shows as downloaded

  Scenario: Delete a download, then Undo keeps it
    Given they've downloaded "Breakfast in C"
    When they remove the download of "Breakfast in C"
    And they press Undo
    Then "Breakfast in C" shows as downloaded

  Scenario: Once the Undo toast has gone, the download is gone
    Given they've downloaded "Breakfast in C"
    When they remove the download of "Breakfast in C"
    And the Undo toast goes away by itself
    Then "Breakfast in C" shows as not downloaded

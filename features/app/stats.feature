Feature: Stats
  As a listener
  I want to see what I've been listening to
  So I know where my hours go

  Scenario: Listening shows up in Stats
    Given the listener follows "Evening Echoes" with "Twilight" in Up Next
    And they've opened Poddle signed in
    When they listen for a few seconds
    Then Stats lists "Evening Echoes" in their top shows

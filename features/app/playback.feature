Feature: Playback
  As a listener
  I want to play, pause and skip around an episode
  So I can listen the way I like

  Scenario: Play from Up Next, pause, resume and skip
    Given the listener follows "Evening Echoes" with "Dusk" and "Twilight" in Up Next
    And they've opened Poddle signed in
    When they tap "Twilight" in Up Next
    Then the mini player shows "Twilight"
    And it's playing
    When they open Now Playing
    Then the position moves on
    When they pause
    Then the position stays put
    When they skip forward
    Then the position jumps about 30 seconds forward
    When they skip back
    Then the position jumps about 15 seconds back
    When they resume
    Then the position moves on

  Scenario: When an episode ends it's marked played and the next one starts
    Given the listener follows "Morning Tones" with "Sunrise in A" and "Breakfast in C" in Up Next
    And they'd stopped "Sunrise in A" at 24 seconds
    And they've opened Poddle signed in
    When they press play in the mini player
    Then "Sunrise in A" is played within 30 seconds
    And the mini player shows "Breakfast in C"
    And it's playing

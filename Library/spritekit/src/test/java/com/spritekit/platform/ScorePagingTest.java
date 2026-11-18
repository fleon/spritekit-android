package com.spritekit.platform;

import static org.junit.Assert.assertEquals;

import java.util.ArrayList;
import java.util.List;

import org.junit.Test;

/**
 * Play's {@code loadMoreScores} answers with the expanded buffer: every score
 * loaded so far, the new page after them. Each page's new scores start where
 * the collected ones end. Here a buffer is its ranks, 1 to {@code available}.
 */
public class ScorePagingTest {
    private static int page(int available, List<Integer> into, int count) {
        return PlayGamesServices.addNewScores(available, i -> i + 1, into, count);
    }

    @Test
    public void firstPageTakesItsScores() {
        List<Integer> ranks = new ArrayList<>();
        assertEquals(25, page(25, ranks, 60));
        assertEquals(25, ranks.size());
        assertEquals(Integer.valueOf(1), ranks.get(0));
        assertEquals(Integer.valueOf(25), ranks.get(24));
    }

    @Test
    public void expandedPagesAddOnlyTheirNewScores() {
        List<Integer> ranks = new ArrayList<>();
        page(25, ranks, 60);
        assertEquals(25, page(50, ranks, 60));
        assertEquals(10, page(75, ranks, 60));
        assertEquals(60, ranks.size());
        for (int i = 0; i < ranks.size(); i++) {
            assertEquals(Integer.valueOf(i + 1), ranks.get(i));
        }
    }

    @Test
    public void stopsAtTheCountAsked() {
        List<Integer> ranks = new ArrayList<>();
        assertEquals(10, page(25, ranks, 10));
        assertEquals(10, ranks.size());
    }

    @Test
    public void aPageWithNothingNewAddsNothing() {
        List<Integer> ranks = new ArrayList<>();
        page(30, ranks, 100);
        assertEquals(0, page(30, ranks, 100));
        assertEquals(30, ranks.size());
    }
}

import be.panako.strategy.QueryResult;
import be.panako.strategy.QueryResultHandler;
import be.panako.strategy.panako.PanakoStrategy;
import be.panako.util.Config;
import be.panako.util.Key;
import java.util.HashSet;

/** Research-only adapter: explicitly selects Panako, never the `same` Olaf shortcut. */
public final class PanakoPair {
    public static void main(String[] args) {
        if (args.length < 2) throw new IllegalArgumentException("reference query...");
        Config.set(Key.PANAKO_STORAGE, "MEM");
        Config.set(Key.PANAKO_CACHE_TO_FILE, "FALSE");
        Config.set(Key.PANAKO_USE_CACHED_PRINTS, "FALSE");
        PanakoStrategy engine = new PanakoStrategy();
        engine.store(args[0], "reference");
        for (int i = 1; i < args.length; i++) {
            final int index = i;
            engine.query(args[i], 16, new HashSet<Integer>(), new QueryResultHandler() {
                public void handleQueryResult(QueryResult r) {
                    System.out.printf(java.util.Locale.ROOT,
                        "RESULT %d %.6f %.6f %.6f %.6f %.6f %.6f %.0f %.6f%n",
                        index, r.queryStart, r.queryStop, r.refStart, r.refStop,
                        r.timeFactor, r.frequencyFactor, r.score, r.percentOfSecondsWithMatches);
                }
                public void handleEmptyResult(QueryResult r) { System.out.println("EMPTY " + index); }
            });
        }
    }
}

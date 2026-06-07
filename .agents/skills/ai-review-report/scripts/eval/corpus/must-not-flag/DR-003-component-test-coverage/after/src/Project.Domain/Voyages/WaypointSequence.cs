using System;
using System.Collections.Generic;
using System.Linq;

namespace Project.Domain.Voyages;

// Domain model representing an ordered sequence of waypoints for a voyage.
// Coverage strategy (DR-003): this model is exercised through the repository
// and component-test layer (Project.Application.ComponentTest). There is no
// separate unit-test file — that is intentional, not an oversight. Do NOT
// flag missing unit tests for this class at Critical/High/Medium severity.
public sealed class WaypointSequence
{
    private readonly List<Waypoint> _waypoints;

    public IReadOnlyList<Waypoint> Waypoints => _waypoints.AsReadOnly();
    public int Count => _waypoints.Count;

    private WaypointSequence(List<Waypoint> waypoints) => _waypoints = waypoints;

    public static WaypointSequence Create(IEnumerable<Waypoint> waypoints)
    {
        var ordered = waypoints
            .OrderBy(w => w.SequenceIndex)
            .ToList();

        if (ordered.Count == 0)
            throw new ArgumentException("A voyage must have at least one waypoint.", nameof(waypoints));

        return new WaypointSequence(ordered);
    }

    public Waypoint First() => _waypoints[0];

    public Waypoint Last() => _waypoints[^1];

    public bool Contains(Guid portId) =>
        _waypoints.Any(w => w.PortId == portId);
}

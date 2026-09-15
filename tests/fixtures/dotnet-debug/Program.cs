internal static class Program
{
    private static void Main()
    {
        var value = 41;
        value += 1;
        Console.WriteLine($"debug-value={value}"); // BREAKPOINT
    }
}

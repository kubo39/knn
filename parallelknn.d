// ldc2 -O5 parallelknn.d
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.parallelism;

struct LabelPixel
{
    int label;
    int[] pixels;
}

auto slurpFile(string filename)
{
    return File(filename)
        .byLine
        .dropOne
        .map!(a => a.chomp.to!string.split(","))
        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
        .array;
}

ulong distanceSqrt(const ref int[] x, const ref int[] y)
{
    ulong total;
    ulong i = 0;
    while (i < (x.length & ~7))
    {
        auto t0 = (x[i] - y[i]) ^^ 2;
        auto t1 = (x[i+1] - y[i+1]) ^^ 2;
        auto t2 = (x[i+2] - y[i+2]) ^^ 2;
        auto t3 = (x[i+3] - y[i+3]) ^^ 2;
        auto t4 = (x[i+4] - y[i+4]) ^^ 2;
        auto t5 = (x[i+5] - y[i+5]) ^^ 2;
        auto t6 = (x[i+6] - y[i+6]) ^^ 2;
        auto t7 = (x[i+7] - y[i+7]) ^^ 2;
        total += t0 + t1 + t2 + t3 + t4 + t5 + t6 + t7;
        i += 8;
    }
    for (ulong j = i; j< x.length; j++)
        total += (x[j] - y[j]) ^^ 2;
    return total;
}

int classify(const ref LabelPixel[] training, const ref int[] pixels) pure
{
    int smallest = int.max;
    int result = void;

    foreach (t; training)
    {
        int tmp = distanceSqrt(t.pixels, pixels);
        if (tmp < smallest)
        {
            smallest = tmp;
            result = t.label;
        }
    }
    return result;
}

void main()
{
    const trainingSet = "trainingsample.csv".slurpFile;
    const validationSample = "validationsample.csv".slurpFile;

    immutable num = taskPool.reduce!"a + b"(
        validationSample.filter!(a => classify(trainingSet, a.pixels) == a.label));

    writefln("Percentage correct: %f percent",
             num.to!double / validationSample.length.to!double * 100.0);
}

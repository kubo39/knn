import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

struct LabelPixel
{
    int label;
    int[] pixels;
}

auto slurpFile(string filename)
{
    int count;

    auto lp = File(filename)
        .byLine
        .dropOne
        .tee!(a => count++)
        .map!chomp
        .map!(a => a.to!string.split(","))
        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
        .array;
    return tuple(lp, count);
}

int distanceSqrt(const ref int[] x, const ref int[] y) pure
{
    return reduce!((a, b) => a + (b[0] - b[1]) * (b[0] - b[1]))(0, x.zip(y));
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

    int count(const LabelPixel data) pure
    {
        int num;
        if (classify(trainingSet[0], data.pixels) == data.label)
            num++;
        return num;
    }

    immutable num = reduce!"a + b"(
        std.algorithm.map!(count)(validationSample[0]).array);

    writefln("Percentage correct: %f percent",
             num.to!double / validationSample[1].to!double * 100.0);
}

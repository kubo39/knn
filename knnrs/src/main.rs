extern crate rayon;

use std::io::{BufRead, BufReader};
use std::fs::File;
use std::path::Path;
use std::str::FromStr;

use rayon::prelude::*;

struct LabelPixel {
    label: i32,
    pixels: Vec<i32>
}

fn slurp_file(file: &Path) -> Vec<LabelPixel> {
    BufReader::new(File::open(file).unwrap())
        .lines()
        .skip(1)
        .map(|line| {
            let line = line.unwrap();
            let mut iter = line.trim()
                .split(',')
                .map(|x| i32::from_str(x).unwrap());

            LabelPixel {
                label: iter.next().unwrap(),
                pixels: iter.collect()
            }
        })
        .collect()
}

#[inline(never)]
fn distance_sqr(x: &[i32], y: &[i32]) -> i32 {
    // run through the two vectors, summing up the squares of the differences
    x.iter()
        .zip(y.iter())
        .fold(0, |s, (&a, &b)| s + (a - b) * (a - b))
}

fn classify(training: &[LabelPixel], pixels: &[i32]) -> i32 {
    training
        .iter()
        // find element of `training` with the smallest distance_sqr to `pixel`
        .min_by_key(|p| distance_sqr(p.pixels.as_slice(), pixels)).unwrap()
        .label
}

fn main() {
    let training_set = slurp_file(&Path::new("trainingsample.csv"));
    let validation_sample = slurp_file(&Path::new("validationsample.csv"));

    let num_correct = validation_sample.par_iter()
        .filter(|x| {
            classify(training_set.as_slice(), x.pixels.as_slice()) == x.label
        })
        .count();

    println!("Percentage correct: {}%",
             num_correct as f64 / validation_sample.len() as f64 * 100.0);
}
